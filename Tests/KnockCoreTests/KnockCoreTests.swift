import XCTest
@testable import KnockCore

/// Synthetic audio helpers: knocks are bursts of exponentially-damped resonances,
/// "speech" is a sustained harmonic tone.
private struct Synth {
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
        let defaults = AppConfig.defaults
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(defaults))
        XCTAssertEqual(roundTrip, defaults)
    }
}
