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
        XCTAssertTrue(config.autoCheckUpdates)
        XCTAssertTrue(config.verifyKnocks)
        XCTAssertTrue(config.requireConsistentPatterns)
        XCTAssertEqual(config.guardSettings, GuardSettings())
        let topic = GuardSettings.randomTopic()
        XCTAssertTrue(topic.hasPrefix("knocksense-"))
        XCTAssertEqual(topic.count, 27)
        XCTAssertNotEqual(topic, GuardSettings.randomTopic())
        // Areas saved by older versions have samples but no peaks.
        let oldZone = #"{"zones":[{"id":"5F3B1C2A-1111-4222-8333-944455556666","name":"Lid","samples":[[1,2],[3,4]]}]}"#
        let withZone = try JSONDecoder().decode(AppConfig.self, from: Data(oldZone.utf8))
        XCTAssertEqual(withZone.zones.first?.peaks, [])
        XCTAssertEqual(withZone.trainedKnocks.count, 2)
        let defaults = AppConfig.defaults
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(defaults))
        XCTAssertEqual(roundTrip, defaults)
    }
}

final class UpdateTests: XCTestCase {
    private let sample = UpdateInfo(build: 7, version: "1.1.0", commit: "abc1234",
                                    sha256: String(repeating: "a1", count: 32),
                                    url: "https://github.com/owner/KnockSense/releases/download/latest/KnockSense.zip")

    func testDecodesManifest() throws {
        let json = #"{"build": 12, "version": "1.1.0", "commit": "74d51cd", "sha256": "\#(String(repeating: "0f", count: 32))", "url": "https://example.com/KnockSense.zip"}"#
        let info = try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.build, 12)
        XCTAssertTrue(UpdatePolicy.isValid(info))
    }

    func testNewerBuildOnly() {
        XCTAssertTrue(UpdatePolicy.isNewer(sample, thanBuild: 6))
        XCTAssertFalse(UpdatePolicy.isNewer(sample, thanBuild: 7))
        XCTAssertFalse(UpdatePolicy.isNewer(sample, thanBuild: 9))
        XCTAssertTrue(UpdatePolicy.isNewer(sample, thanBuild: 0))   // local builds always accept releases
    }

    func testRejectsBadManifests() {
        let badHash = UpdateInfo(build: 7, version: "1", commit: "x", sha256: "nothex", url: sample.url)
        let http = UpdateInfo(build: 7, version: "1", commit: "x", sha256: sample.sha256, url: "http://example.com/a.zip")
        XCTAssertTrue(UpdatePolicy.isValid(sample))
        XCTAssertFalse(UpdatePolicy.isValid(badHash))
        XCTAssertFalse(UpdatePolicy.isValid(http))
    }

    func testInstallPlan() {
        XCTAssertEqual(UpdatePolicy.installPlan(appPath: "/Applications/KnockSense.app", parentIsWritable: true, applicationsIsWritable: true),
                       .replace("/Applications/KnockSense.app"))
        // Opened from Downloads: macOS runs a read-only shadow copy, so install into Applications instead.
        let shadow = "/private/var/folders/xy/T/AppTranslocation/1234/d/KnockSense.app"
        XCTAssertEqual(UpdatePolicy.installPlan(appPath: shadow, parentIsWritable: false, applicationsIsWritable: true),
                       .installInto("/Applications/KnockSense.app"))
        if case .impossible = UpdatePolicy.installPlan(appPath: shadow, parentIsWritable: false, applicationsIsWritable: false) {} else { XCTFail() }
        if case .impossible = UpdatePolicy.installPlan(appPath: "/Applications/KnockSense.app", parentIsWritable: false, applicationsIsWritable: true) {} else { XCTFail() }
        if case .impossible = UpdatePolicy.installPlan(appPath: "/usr/local/bin/KnockSense", parentIsWritable: true, applicationsIsWritable: true) {} else { XCTFail() }
    }
}

final class BuiltinActionTests: XCTestCase {
    func testScreenshotActionsAreDistinctAndOldRulesStillDecode() throws {
        XCTAssertTrue(BuiltinAction.allCases.contains(.screenshotToClipboard))
        XCTAssertTrue(BuiltinAction.allCases.contains(.screenshotAreaToClipboard))
        XCTAssertEqual(Set(BuiltinAction.allCases.map(\.title)).count, BuiltinAction.allCases.count)
        // Rules saved by older versions use the raw value "screenshot" and must keep working.
        let json = #"{"kind":"builtin","argument":"screenshot"}"#
        let action = try JSONDecoder().decode(KnockAction.self, from: Data(json.utf8))
        XCTAssertEqual(BuiltinAction(rawValue: action.argument), .screenshot)
        XCTAssertEqual(KnockAction.builtin(.screenshotToClipboard).summary, "Screenshot to clipboard (whole screen)")
    }
}

extension Synth {
    /// A door opening/closing nearby: a light latch click, then ~0.25 s later a heavy low thud.
    func addDoor(_ x: inout [Float], at t: Double, amp: Float = 0.2) {
        addKnocks(&x, at: [t], amp: amp * 0.7, modes: [1800, 4200, 6100])          // latch click
        let start = Int((t + 0.25) * sampleRate)                                       // door hits frame
        for i in 0..<Int(0.15 * sampleRate) where start + i < x.count {
            let tt = Double(i) / sampleRate
            let v = sin(2 * .pi * 70 * tt) + 0.8 * sin(2 * .pi * 140 * tt) + 0.5 * sin(2 * .pi * 310 * tt)
            x[start + i] += Float(Double(amp) * exp(-tt / 0.02) * v / 2.3)
        }
    }
}

/// Runs the detector and returns (features, peak, time) for each detected sound.
func detectSounds(_ x: [Float], sensitivity: Double = 0.5) -> [(features: [Double], peak: Float, time: Double)] {
    let detector = KnockDetector(sampleRate: 48_000, channelCount: 2, params: .forSensitivity(sensitivity))
    var out: [(features: [Double], peak: Float, time: Double)] = []
    var i = 0
    while i < x.count {
        let chunk = Array(x[i..<min(i + 1024, x.count)])
        for e in detector.process([chunk, chunk.map { $0 * 0.8 }]) {
            out.append((FeatureExtractor.extract(e), e.peak, Double(e.onsetSample) / 48_000))
        }
        i += 1024
    }
    return out
}

/// Everyday sounds (a door opening) must not count as a deliberate double knock.
final class FalseTriggerTests: XCTestCase {
    private var synth = Synth()

    private func samples(_ x: [Float]) -> [SoundSample] {
        detectSounds(x).map { SoundSample(features: $0.features, peak: $0.peak) }
    }

    /// 8 training knocks with natural variation in force and resonance ("Teach my knock").
    private func trainedKnocks() -> [SoundSample] {
        var train = synth.signal(duration: 9)
        for i in 0..<8 {
            let jitter = 1 + Double(i % 3 - 1) * 0.04
            synth.addKnocks(&train, at: [0.5 + Double(i)], amp: 0.3 + Float(i % 4) * 0.06,
                            modes: [400 * jitter, 1500 * jitter, 3200 * jitter])
        }
        return samples(train)
    }

    private func doorSounds(amp: Float = 0.2) -> [SoundSample] {
        var x = synth.signal(duration: 2)
        synth.addDoor(&x, at: 0.5, amp: amp)
        return samples(x)
    }

    func testDoorLooksLikeTwoKnocksToTheRawDetector() {
        // This is the bug: without the new checks a door is a "double knock".
        XCTAssertEqual(doorSounds().count, 2)
    }

    func testDoorIsNotAConsistentPattern() {
        XCTAssertFalse(PatternConsistency.isConsistent(doorSounds()))
        XCTAssertFalse(PatternConsistency.isConsistent(doorSounds(amp: 0.5)))
    }

    func testRealDoubleKnockIsConsistent() {
        var x = synth.signal(duration: 2)
        synth.addKnocks(&x, at: [0.5, 0.75], amp: 0.35)
        synth.addKnocks(&x, at: [1.4], amp: 0.2)      // softer third knock still matches
        XCTAssertTrue(PatternConsistency.isConsistent(samples(x)))
    }

    func testVerifierAcceptsYourKnocksIncludingDuringAMovie() {
        let knocks = trainedKnocks()
        XCTAssertEqual(knocks.count, 8)
        var quiet = synth.signal(duration: 2)
        synth.addKnocks(&quiet, at: [0.5, 0.75], amp: 0.35)
        var movie = synth.movie(duration: 4, rms: 0.06)
        synth.addKnocks(&movie, at: [2.0, 2.25], amp: 0.4)
        for sound in samples(quiet) + samples(movie) {
            XCTAssertEqual(KnockVerifier.verify(sound, knocks: knocks, rejected: []), .accepted)
        }
    }

    func testVerifierRejectsDoor() {
        let knocks = trainedKnocks()
        for sound in doorSounds() + doorSounds(amp: 0.5) {
            XCTAssertNotEqual(KnockVerifier.verify(sound, knocks: knocks, rejected: []), .accepted)
        }
    }

    func testVerifierRejectsMuchQuieterSounds() {
        let knocks = trainedKnocks()
        var x = synth.signal(duration: 2)
        synth.addKnocks(&x, at: [0.5], amp: 0.06)     // same kind of sound, far away / very light
        // At the highest sensitivity the detector hears it; the loudness check must still reject it.
        let faint = detectSounds(x, sensitivity: 1).map { SoundSample(features: $0.features, peak: $0.peak) }
        XCTAssertEqual(faint.count, 1)
        guard let sound = faint.first else { return }
        XCTAssertEqual(KnockVerifier.verify(sound, knocks: knocks, rejected: []), .tooQuiet)
    }

    func testThatWasntMeLearnsTheSound() {
        let knocks = trainedKnocks()
        // A knock-ish sound that is a bit different (e.g. something tapping the desk).
        var desk = synth.signal(duration: 3)
        synth.addKnocks(&desk, at: [0.5], amp: 0.35, modes: [300, 1100, 2600])
        synth.addKnocks(&desk, at: [1.5], amp: 0.3, modes: [310, 1150, 2550])
        let deskSounds = samples(desk)
        XCTAssertEqual(deskSounds.count, 2)
        guard deskSounds.count == 2 else { return }
        // User presses "That wasn't me" after the first one…
        let rejected = [deskSounds[0].features]
        // …so the next similar sound is ignored, while real knocks still work.
        XCTAssertEqual(KnockVerifier.verify(deskSounds[1], knocks: knocks, rejected: rejected), .markedAsNotAKnock)
        var mine = synth.signal(duration: 2)
        synth.addKnocks(&mine, at: [0.5], amp: 0.35)
        guard let myKnock = samples(mine).first else { return XCTFail("knock not detected") }
        XCTAssertEqual(KnockVerifier.verify(myKnock, knocks: knocks, rejected: rejected), .accepted)
    }

    func testVerifierStaysOffUntilTrained() {
        guard let sound = doorSounds().first else { return XCTFail("door not detected") }
        XCTAssertEqual(KnockVerifier.verify(sound, knocks: [], rejected: []), .notTrained)
    }
}

/// Simulated accelerometer: 800 Hz, gravity mostly on −z, 2 mg sensor noise.
struct MotionSynth {
    var seed: UInt64 = 0xABCDEF
    let rate = 800.0

    mutating func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }

    /// Returns samples (t, x, y, z).
    mutating func samples(duration: Double,
                          taps: [(t: Double, amp: Double, dir: (Double, Double, Double))] = [],
                          typing: [Double] = [],
                          lift: (start: Double, end: Double)? = nil) -> [(Double, Double, Double, Double)] {
        let n = Int(duration * rate)
        var out: [(Double, Double, Double, Double)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / rate
            var x = 0.05 + noise() * 0.002, y = 0.02 + noise() * 0.002, z = -0.998 + noise() * 0.002
            for tap in taps where t >= tap.t && t < tap.t + 0.1 {
                let tt = t - tap.t
                let v = tap.amp * exp(-tt / 0.006) * sin(2 * .pi * 230 * tt + 0.3)
                x += v * tap.dir.0; y += v * tap.dir.1; z += v * tap.dir.2
            }
            for k in typing where t >= k && t < k + 0.03 {        // key presses: tiny vibrations
                let tt = t - k
                z += 0.006 * exp(-tt / 0.004) * sin(2 * .pi * 300 * tt)
            }
            if let lift, t >= lift.start && t < lift.end {       // picking up and carrying the Mac
                let tt = t - lift.start
                z += 0.25 * sin(2 * .pi * 1.2 * tt) + 0.05 * sin(2 * .pi * 7 * tt)
                x += 0.15 * sin(2 * .pi * 0.8 * tt)
            }
            out.append((t, x, y, z))
        }
        return out
    }
}

private func detectTaps(_ samples: [(Double, Double, Double, Double)], sensitivity: Double = 0.5) -> [TapEvent] {
    let detector = TapDetector(params: .forSensitivity(sensitivity))
    return samples.compactMap { detector.process(t: $0.0, x: $0.1, y: $0.2, z: $0.3) }
}

final class MotionSensorTests: XCTestCase {
    func testDetectsKnocksIncludingFastDoubleKnock() {
        var m = MotionSynth()
        let down = (0.1, 0.0, -0.99)
        let taps = detectTaps(m.samples(duration: 4, taps: [(1.0, 0.15, down), (1.2, 0.12, down), (2.5, 0.2, down), (3.0, 0.1, down)]))
        XCTAssertEqual(taps.count, 4)
        XCTAssertEqual(taps.first?.time ?? 0, 1.0, accuracy: 0.01)
    }

    func testTypingIsNotAKnock() {
        var m = MotionSynth()
        let keys = stride(from: 0.5, to: 3.5, by: 0.12).map { $0 }
        XCTAssertEqual(detectTaps(m.samples(duration: 4, typing: keys)).count, 0)
    }

    func testLiftingAndCarryingIsNotAKnock() {
        var m = MotionSynth()
        XCTAssertEqual(detectTaps(m.samples(duration: 5, lift: (1.0, 4.0))).count, 0)
    }

    func testSensitivityControlsLightTaps() {
        var m = MotionSynth()
        let light = m.samples(duration: 2, taps: [(1.0, 0.02, (0, 0, -1))])
        XCTAssertEqual(detectTaps(light, sensitivity: 0.2).count, 0)
        XCTAssertEqual(detectTaps(light, sensitivity: 1).count, 1)
    }

    func testDirectionTellsAreasApart() {
        var m = MotionSynth()
        let left = (-0.6, 0.1, -0.79), lid = (0.0, 0.95, -0.3)
        func taps(_ dir: (Double, Double, Double), _ count: Int) -> [TapEvent] {
            let times = (0..<count).map { 0.5 + Double($0) * 0.4 }
            return detectTaps(m.samples(duration: 0.5 + Double(count) * 0.4 + 0.3,
                                        taps: times.enumerated().map { (i, t) in (t, 0.1 + Double(i % 3) * 0.03, dir) }))
        }
        let leftID = UUID(), lidID = UUID()
        let zones = [Zone(id: leftID, name: "Left", samples: taps(left, 6).map(\.features)),
                     Zone(id: lidID, name: "Lid", samples: taps(lid, 6).map(\.features))]
        XCTAssertEqual(zones[0].samples.count, 6)
        for t in taps(left, 3) { XCTAssertEqual(ZoneClassifier.classify(t.features, zones: zones)?.zoneID, leftID) }
        for t in taps(lid, 3) { XCTAssertEqual(ZoneClassifier.classify(t.features, zones: zones)?.zoneID, lidID) }
    }

    func testMotionKnocksSkipMicrophoneOnlyChecks() {
        let a = SoundSample(features: [0.1, 0.0, -0.99], peak: 0.1)
        let b = SoundSample(features: [-0.2, 0.3, -0.9], peak: 0.12)
        XCTAssertTrue(PatternConsistency.isConsistent([a, b]))
        XCTAssertEqual(KnockVerifier.verify(a, knocks: [b, b, b, b, b], rejected: []), .notTrained)
    }
}

final class MovementDetectorTests: XCTestCase {
    private func run(_ samples: [(Double, Double, Double, Double)]) -> [MovementReason] {
        let detector = MovementDetector()
        return samples.compactMap { detector.process(t: $0.0, x: $0.1, y: $0.2, z: $0.3) }
    }

    func testStillMacDoesNotTrigger() {
        var m = MotionSynth()
        XCTAssertTrue(run(m.samples(duration: 6)).isEmpty)
    }

    func testTypingAndKnocksNearbyDoNotTrigger() {
        var m = MotionSynth()
        let keys = stride(from: 1.5, to: 5.5, by: 0.1).map { $0 }
        let taps = [(2.0, 0.15, (0.0, 0.0, -1.0)), (3.0, 0.2, (0.0, 0.0, -1.0))]
        XCTAssertTrue(run(m.samples(duration: 6, taps: taps, typing: keys)).isEmpty)
    }

    func testPickingUpTheMacTriggersOnce() {
        var m = MotionSynth()
        let reasons = run(m.samples(duration: 6, lift: (2.0, 5.0)))
        XCTAssertEqual(reasons.count, 1)
    }

    func testSlowlyTiltingTheMacTriggers() {
        // Tilt by 12° over 2 s (someone gently sliding the lid / lifting one side).
        var samples: [(Double, Double, Double, Double)] = []
        for i in 0..<Int(6 * 800.0) {
            let t = Double(i) / 800
            let angle = t < 2 ? 0 : min(12, (t - 2) * 6) * .pi / 180
            samples.append((t, sin(angle), 0, -cos(angle)))
        }
        let reasons = run(samples)
        XCTAssertEqual(reasons.count, 1)
        if case .tilted(let degrees)? = reasons.first { XCTAssertGreaterThan(degrees, 6) } else { XCTFail("expected tilt") }
    }

    func testResetRearms() {
        let detector = MovementDetector()
        var m = MotionSynth()
        let lift = m.samples(duration: 6, lift: (2.0, 5.0))
        XCTAssertEqual(lift.compactMap { detector.process(t: $0.0, x: $0.1, y: $0.2, z: $0.3) }.count, 1)
        detector.reset()
        XCTAssertEqual(lift.compactMap { detector.process(t: $0.0 + 10, x: $0.1, y: $0.2, z: $0.3) }.count, 1)
    }
}

