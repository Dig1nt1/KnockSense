import XCTest
@testable import KnockCore

/// Synthetic audio helpers: knocks are bursts of exponentially-damped resonances,
/// "speech" is a sustained harmonic tone.
struct Synth {
    var seed: UInt64 = 0x1234_5678
    let sampleRate: Double = 48_000

    mutating func noise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Double(seed >> 11) / Double(UInt64(1) << 53)) * 2 - 1
    }

    mutating func signal(duration: Double, noiseLevel: Float = 0.002,
                         knocks: [(t: Double, amp: Float, modes: [Double])] = [],
                         tones: [(t: Double, dur: Double, amp: Float)] = []) -> [Float] {
        let n = Int(duration * sampleRate)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = noise() * noiseLevel }
        for k in knocks {
            let start = Int(k.t * sampleRate)
            for i in 0..<Int(0.08 * sampleRate) where start + i < n {
                let t = Double(i) / sampleRate
                var v = 0.0
                for f in k.modes { v += sin(2 * .pi * f * t) }
                x[start + i] += Float(Double(k.amp) * exp(-t / 0.006) * v / Double(k.modes.count))
            }
        }
        for tone in tones {
            let start = Int(tone.t * sampleRate)
            for i in 0..<Int(tone.dur * sampleRate) where start + i < n {
                let t = Double(i) / sampleRate
                let ramp = min(1, t / 0.02)
                let v = (sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 440 * t)) / 1.5
                x[start + i] += Float(Double(tone.amp) * ramp * v)
            }
        }
        return x
    }
}

extension Synth {
    /// Film-like soundtrack as heard by the Mac's mic: a music bed with chord changes plus
    /// dialogue syllables (sharp-ish onsets, 80–250 ms long, varying pitch), scaled to `rms`.
    mutating func movie(duration: Double, rms: Float) -> [Float] {
        let n = Int(duration * sampleRate)
        var x = [Float](repeating: 0, count: n)
        // Music bed: chords changing every 0.6 s, slow swells.
        let chords: [[Double]] = [[110, 220, 277, 330], [98, 196, 247, 294], [87, 175, 220, 262], [131, 262, 330, 392]]
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let chord = chords[Int(t / 0.6) % chords.count]
            let swell = 0.6 + 0.4 * sin(2 * .pi * 0.3 * t)
            var v = 0.0
            for f in chord { v += sin(2 * .pi * f * t) }
            x[i] = Float(0.35 * swell * v / Double(chord.count)) + noise() * 0.05
        }
        // Dialogue: syllables with 10 ms attacks.
        var t = 0.05
        while t < duration {
            let len = 0.08 + Double(abs(noise())) * 0.17
            let pitch = 120 + Double(abs(noise())) * 180
            let amp = 0.8 + Double(noise()) * 0.3
            let start = Int(t * sampleRate)
            for i in 0..<Int(len * sampleRate) where start + i < n {
                let tt = Double(i) / sampleRate
                let env = min(1, tt / 0.01) * min(1, (len - tt) / 0.03)
                var v = 0.0
                for h in 1...6 { v += sin(2 * .pi * pitch * Double(h) * tt) / Double(h) }
                x[start + i] += Float(amp * env * v * 0.6) + noise() * Float(0.15 * env)
            }
            t += len + 0.03 + Double(abs(noise())) * 0.25
        }
        // Normalise to the requested RMS.
        let current = sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(n))
        return x.map { $0 * rms / current }
    }

    /// Adds knocks (damped resonances) on top of an existing signal.
    func addKnocks(_ x: inout [Float], at times: [Double], amp: Float, modes: [Double] = [400, 1500, 3200]) {
        for k in times {
            let start = Int(k * sampleRate)
            for i in 0..<Int(0.08 * sampleRate) where start + i < x.count {
                let t = Double(i) / sampleRate
                var v = 0.0
                for f in modes { v += sin(2 * .pi * f * t) }
                x[start + i] += Float(Double(amp) * exp(-t / 0.006) * v / Double(modes.count))
            }
        }
    }
}

/// Knocking while a movie plays: the soundtrack comes out of the speakers into the mic.
final class MovieAudioTests: XCTestCase {
    private let knockTimes = [2.0, 2.25, 5.0, 5.25, 5.5, 8.0, 8.25, 11.0, 11.3, 14.0, 14.25, 17.0]

    private func knocksDetected(movieRMS: Float, sensitivity: Double = 0.5) -> (knocks: Int, falseAlarms: Int) {
        var s = Synth()
        var x = s.movie(duration: 20, rms: movieRMS)
        let falseAlarms = detect(x, params: .forSensitivity(sensitivity)).count
        s.addKnocks(&x, at: knockTimes, amp: 0.4)
        return (detect(x, params: .forSensitivity(sensitivity)).count, falseAlarms)
    }

    func testDetectsKnocksOverQuietMovie() {
        XCTAssertEqual(knocksDetected(movieRMS: 0.03).knocks, knockTimes.count)
    }

    func testDetectsKnocksOverNormalMovie() {
        XCTAssertEqual(knocksDetected(movieRMS: 0.06).knocks, knockTimes.count)
    }

    func testDetectsMostKnocksOverLoudMovie() {
        XCTAssertGreaterThanOrEqual(knocksDetected(movieRMS: 0.1).knocks, knockTimes.count - 2)
    }

    func testMovieDialogueAndMusicAreNotKnocks() {
        for rms: Float in [0.03, 0.06, 0.1, 0.15] {
            XCTAssertEqual(knocksDetected(movieRMS: rms).falseAlarms, 0, "movie rms \(rms)")
        }
    }

    func testHighSensitivityStaysUsableDuringMovie() {
        let result = knocksDetected(movieRMS: 0.1, sensitivity: 1)
        XCTAssertGreaterThanOrEqual(result.knocks - result.falseAlarms, knockTimes.count - 1)
        XCTAssertLessThanOrEqual(result.falseAlarms, 1)
    }
}

/// Feeds a mono signal to the detector as 2-channel audio in 1024-frame buffers.
private func detect(_ x: [Float], params: DetectorParams = .forSensitivity(0.5), sampleRate: Double = 48_000) -> [KnockEvent] {
    let detector = KnockDetector(sampleRate: sampleRate, channelCount: 2, params: params)
    var events: [KnockEvent] = []
    var i = 0
    while i < x.count {
        let chunk = Array(x[i..<min(i + 1024, x.count)])
        events += detector.process([chunk, chunk.map { $0 * 0.8 }])
        i += 1024
    }
    return events
}

final class DetectorTests: XCTestCase {
    func testDetectsTripleKnock() {
        var s = Synth()
        let modes = [400.0, 1500, 3200]
        let x = s.signal(duration: 3, knocks: [(1.0, 0.4, modes), (1.22, 0.35, modes), (1.45, 0.4, modes)])
        XCTAssertEqual(detect(x).count, 3)
    }

    func testIgnoresSustainedSpeechLikeSound() {
        var s = Synth()
        let x = s.signal(duration: 3, tones: [(1.0, 0.4, 0.3), (1.8, 0.25, 0.3)])
        XCTAssertEqual(detect(x).count, 0)
    }

    func testIgnoresKnocksBelowSensitivity() {
        var s = Synth()
        let x = s.signal(duration: 2, knocks: [(1.0, 0.03, [500, 2000])])
        XCTAssertEqual(detect(x, params: .forSensitivity(0)).count, 0)
        XCTAssertEqual(detect(x, params: .forSensitivity(1)).count, 1)
    }

    func testEventWindowShape() throws {
        var s = Synth()
        let x = s.signal(duration: 2, knocks: [(1.0, 0.4, [600, 2500])])
        let event = try XCTUnwrap(detect(x).first)
        XCTAssertEqual(event.window.count, 2)
        XCTAssertEqual(event.window[0].count, 2048)
        XCTAssertGreaterThan(event.peak, 0.2)
    }

    func testWorksAtLowSampleRate() {
        var s = Synth()
        let x = s.signal(duration: 2, knocks: [(1.0, 0.4, [500, 1800])])
        // Re-interpret the 48 kHz synth as 16 kHz audio; detection must still work.
        let decimated = stride(from: 0, to: x.count, by: 3).map { x[$0] }
        XCTAssertEqual(detect(decimated, sampleRate: 16_000).count, 1)
    }
}

final class ClassifierTests: XCTestCase {
    func testDistinguishesZonesBySound() {
        var s = Synth()
        let zoneA = UUID(), zoneB = UUID()
        func knockFeatures(_ modes: [Double], count: Int) -> [[Double]] {
            (0..<count).compactMap { i in
                let jitter = 1 + Double(i % 3 - 1) * 0.04
                let x = s.signal(duration: 1.2, knocks: [(0.8, 0.3 + Float(i % 4) * 0.05, modes.map { $0 * jitter })])
                return detect(x).first.map(FeatureExtractor.extract)
            }
        }
        let lowModes = [250.0, 900], highModes = [1800.0, 5200]
        let zones = [
            Zone(id: zoneA, name: "Palm rest", samples: knockFeatures(lowModes, count: 6)),
            Zone(id: zoneB, name: "Lid", samples: knockFeatures(highModes, count: 6)),
        ]
        XCTAssertEqual(zones[0].samples.count, 6)

        let testA = knockFeatures(lowModes, count: 3)
        let testB = knockFeatures(highModes, count: 3)
        for f in testA { XCTAssertEqual(ZoneClassifier.classify(f, zones: zones)?.zoneID, zoneA) }
        for f in testB { XCTAssertEqual(ZoneClassifier.classify(f, zones: zones)?.zoneID, zoneB) }
        XCTAssertEqual(ZoneClassifier.selfTestAccuracy(zones: zones) ?? 0, 1, accuracy: 0.001)
    }

    func testIgnoresSamplesOfDifferentDimension() {
        let zone = Zone(name: "Old mic", samples: [[1, 2, 3]])
        XCTAssertNil(ZoneClassifier.classify([1, 2, 3, 4], zones: [zone]))
        XCTAssertNil(ZoneClassifier.selfTestAccuracy(zones: [zone]))
    }

    func testFFTOfSine() {
        let n = 256
        let x = (0..<n).map { Float(sin(2 * Double.pi * 8 * Double($0) / Double(n))) }
        let p = FFT.powerSpectrum(x)
        XCTAssertEqual(p.indices.max { p[$0] < p[$1] }, 8)
    }
}

final class PatternTests: XCTestCase {
    func testGroupsKnocksByGap() {
        let g = PatternGrouper(gap: 0.4, maxCount: 4)
        XCTAssertTrue(g.add(at: 0.0, zone: nil).isEmpty)
        XCTAssertTrue(g.add(at: 0.25, zone: nil).isEmpty)
        XCTAssertNil(g.poll(now: 0.5))
        XCTAssertEqual(g.poll(now: 0.7), KnockPattern(count: 2, zoneID: nil))
        XCTAssertNil(g.poll(now: 2))
    }

    func testFiresImmediatelyAtMaxCount() {
        let g = PatternGrouper(gap: 0.4, maxCount: 2)
        _ = g.add(at: 0, zone: nil)
        XCTAssertEqual(g.add(at: 0.2, zone: nil), [KnockPattern(count: 2, zoneID: nil)])
    }

    func testLateKnockStartsNewPatternWithoutPoll() {
        let g = PatternGrouper(gap: 0.4, maxCount: 4)
        _ = g.add(at: 0, zone: nil)
        XCTAssertEqual(g.add(at: 1.0, zone: nil), [KnockPattern(count: 1, zoneID: nil)])
        XCTAssertEqual(g.pendingCount, 1)
    }

    func testMajorityZone() {
        let a = UUID(), b = UUID()
        let g = PatternGrouper(gap: 0.4, maxCount: 3)
        _ = g.add(at: 0, zone: a)
        _ = g.add(at: 0.2, zone: b)
        XCTAssertEqual(g.add(at: 0.4, zone: b).first?.zoneID, b)
    }

    func testSpecificZoneRuleWins() {
        let lid = UUID()
        let anywhere = Rule(name: "any", knockCount: 2, action: .builtin(.playPause))
        let onLid = Rule(name: "lid", knockCount: 2, zoneID: lid, action: .builtin(.lockScreen))
        let disabled = Rule(name: "off", enabled: false, knockCount: 3, action: .builtin(.notify))
        let rules = [anywhere, onLid, disabled]
        XCTAssertEqual(RuleMatcher.match(KnockPattern(count: 2, zoneID: lid), rules: rules), [onLid])
        XCTAssertEqual(RuleMatcher.match(KnockPattern(count: 2, zoneID: UUID()), rules: rules), [anywhere])
        XCTAssertEqual(RuleMatcher.match(KnockPattern(count: 3, zoneID: nil), rules: rules), [])
        XCTAssertEqual(RuleMatcher.maxKnockCount(in: rules), 2)
    }

    func testConfigDecodesOldFilesWithMissingFields() throws {
        let json = #"{"sensitivity":0.8,"rules":[]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.sensitivity, 0.8)
        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.ignoreWhileTyping)
        XCTAssertTrue(config.useBuiltInMic)
        let defaults = AppConfig.defaults
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(defaults))
        XCTAssertEqual(roundTrip, defaults)
    }
}
