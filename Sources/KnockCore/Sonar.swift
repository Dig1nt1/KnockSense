import Foundation

// MARK: - Sonar analysis

/// Measures movement in front of the Mac from the echo of an inaudible tone.
///
/// The microphone signal is mixed down around the tone's frequency (like a Doppler radar): the static
/// echo from walls and furniture becomes a constant, while anything that moves (a person breathing,
/// shifting, typing) makes the echo's phase wobble. Only human-speed wobble (≈0.15–6 Hz) is measured,
/// and the microphone's own hiss is measured the same way just beside the tone (where there is no
/// echo) and subtracted, so an empty room reads close to zero. The result is relative to the tone's
/// strength, so it doesn't depend on volume. Not thread-safe: call from one queue.
public final class SonarAnalyzer {
    public struct Reading: Equatable, Sendable {
        /// Movement energy relative to the tone's strength (dimensionless, hiss removed).
        public let motion: Double
        /// Strength of the tone as heard by the microphone (amplitude, 0…1).
        public let toneLevel: Double
        /// Microphone hiss in the same band, relative to the tone (diagnostic).
        public var hiss: Double = 0
        /// How fast the received tone drifts against the microphone's clock, in Hz (diagnostic).
        public var drift: Double = 0

        public init(motion: Double, toneLevel: Double, hiss: Double = 0, drift: Double = 0) {
            self.motion = motion
            self.toneLevel = toneLevel
            self.hiss = hiss
            self.drift = drift
        }
    }

    public let sampleRate: Double
    public let toneFrequency: Double
    /// Offset of the hiss reference from the tone (a multiple of the 200 Hz baseband rate, so tone
    /// leakage lands on DC and is removed).
    static let referenceOffset = 600.0

    private var tone: Channel
    private var reference: Channel
    private let decimation: Int
    private var blockCount = 0
    private var motionSum = 0.0, hissSum = 0.0, toneSum = 0.0, readingCount = 0
    private let samplesPerReading: Int
    /// Recent per-reading motion values; each reading reports their average (~2 s), which steadies
    /// the leftover hiss. Presence doesn't need to react faster than that.
    private var recentMotion: [Double] = []
    private let smoothingCount: Int

    public init(sampleRate: Double, toneFrequency: Double = 19_500, readingsPerSecond: Double = 4) {
        self.sampleRate = sampleRate
        self.toneFrequency = toneFrequency
        decimation = max(1, Int(sampleRate / 200))
        let basebandRate = sampleRate / Double(decimation)
        tone = Channel(frequency: toneFrequency, sampleRate: sampleRate, basebandRate: basebandRate, tracksDrift: true)
        reference = Channel(frequency: toneFrequency - Self.referenceOffset, sampleRate: sampleRate,
                            basebandRate: basebandRate, tracksDrift: false)
        samplesPerReading = max(1, Int(basebandRate / readingsPerSecond))
        smoothingCount = max(1, Int(2 * readingsPerSecond))
    }

    public func process(_ samples: [Float]) -> [Reading] {
        var readings: [Reading] = []
        for sample in samples {
            let x = Double(sample)
            tone.mix(x)
            reference.mix(x)
            blockCount += 1
            guard blockCount == decimation else { continue }
            blockCount = 0
            let t = tone.baseband(decimation)
            let r = reference.baseband(decimation)
            motionSum += t.motion
            hissSum += r.motion
            toneSum += t.power
            readingCount += 1
            guard readingCount == samplesPerReading else { continue }
            let toneMean = toneSum / Double(readingCount)
            let hissMean = hissSum / Double(readingCount)
            // Keep the sign until after averaging: clamping each reading would turn random hiss into a
            // steady positive bias.
            let motion = (motionSum - hissSum) / Double(readingCount)
            motionSum = 0
            hissSum = 0
            toneSum = 0
            readingCount = 0
            recentMotion.append(toneMean > 0 ? motion / toneMean : 0)
            if recentMotion.count > smoothingCount { recentMotion.removeFirst(recentMotion.count - smoothingCount) }
            let smoothed = max(0, recentMotion.reduce(0, +) / Double(recentMotion.count))
            // Mixing halves the amplitude; ×2 gives the tone's amplitude in the microphone signal.
            readings.append(Reading(motion: smoothed, toneLevel: 2 * toneMean.squareRoot(),
                                    hiss: toneMean > 0 ? hissMean / toneMean : 0, drift: tone.driftHz))
        }
        return readings
    }

    /// One mixer: oscillator → low-pass → 200 Hz baseband → remove static part → keep 0.15–6 Hz.
    private struct Channel {
        private var oscRe = 1.0, oscIm = 0.0
        private let stepRe: Double, stepIm: Double
        private var renormalizeCounter = 0
        private var lowI1: Biquad, lowI2: Biquad, lowQ1: Biquad, lowQ2: Biquad
        private var blockI = 0.0, blockQ = 0.0
        private var dcI = 0.0, dcQ = 0.0
        private var dcPrimed = false
        private let dcAlpha: Double
        private var slowI: Biquad, slowQ: Biquad
        // Clock-drift tracking: the speaker and microphone run on separate clocks, so the received
        // tone slowly rotates against our oscillator. That steady rotation is measured and undone;
        // a person's movement wobbles back and forth and survives.
        private let tracksDrift: Bool
        private let basebandRate: Double
        private var previousI = 0.0, previousQ = 0.0, hasPrevious = false
        private var advanceRe = 0.0, advanceIm = 0.0
        private let advanceAlpha: Double
        private var derotation = 0.0
        private(set) var driftHz = 0.0

        init(frequency: Double, sampleRate: Double, basebandRate: Double, tracksDrift: Bool) {
            self.tracksDrift = tracksDrift
            self.basebandRate = basebandRate
            advanceAlpha = 1 - exp(-1 / (5 * basebandRate))       // ~5 s average
            let w = 2 * Double.pi * frequency / sampleRate
            stepRe = cos(w)
            stepIm = -sin(w)
            lowI1 = .lowPass(cutoff: 120, sampleRate: sampleRate)
            lowI2 = .lowPass(cutoff: 120, sampleRate: sampleRate)
            lowQ1 = .lowPass(cutoff: 120, sampleRate: sampleRate)
            lowQ2 = .lowPass(cutoff: 120, sampleRate: sampleRate)
            dcAlpha = 1 - exp(-2 * Double.pi * 0.15 / basebandRate)
            slowI = .lowPass(cutoff: 6, sampleRate: basebandRate)
            slowQ = .lowPass(cutoff: 6, sampleRate: basebandRate)
        }

        mutating func mix(_ x: Double) {
            blockI += lowI2.process(lowI1.process(x * oscRe))
            blockQ += lowQ2.process(lowQ1.process(x * oscIm))
            let re = oscRe * stepRe - oscIm * stepIm
            oscIm = oscRe * stepIm + oscIm * stepRe
            oscRe = re
            renormalizeCounter += 1
            if renormalizeCounter >= 4096 {
                let magnitude = (oscRe * oscRe + oscIm * oscIm).squareRoot()
                oscRe /= magnitude
                oscIm /= magnitude
                renormalizeCounter = 0
            }
        }

        /// Called once per decimation block: returns movement-band energy and total power.
        mutating func baseband(_ decimation: Int) -> (motion: Double, power: Double) {
            var i = blockI / Double(decimation), q = blockQ / Double(decimation)
            blockI = 0
            blockQ = 0
            let power = i * i + q * q
            if tracksDrift {
                if hasPrevious {
                    // z · conj(previous): its angle is how far the tone turned since the last sample.
                    let re = i * previousI + q * previousQ
                    let im = q * previousI - i * previousQ
                    advanceRe += (re - advanceRe) * advanceAlpha
                    advanceIm += (im - advanceIm) * advanceAlpha
                }
                previousI = i
                previousQ = q
                hasPrevious = true
                let step = atan2(advanceIm, advanceRe)
                driftHz = step * basebandRate / (2 * Double.pi)
                derotation += step
                if derotation > Double.pi { derotation -= 2 * Double.pi } else if derotation < -Double.pi { derotation += 2 * Double.pi }
                let c = cos(derotation), sn = sin(derotation)
                (i, q) = (i * c + q * sn, q * c - i * sn)
            }
            if !dcPrimed {
                dcI = i
                dcQ = q
                dcPrimed = true
            }
            dcI += (i - dcI) * dcAlpha
            dcQ += (q - dcQ) * dcAlpha
            let mi = slowI.process(i - dcI), mq = slowQ.process(q - dcQ)
            return (mi * mi + mq * mq, power)
        }
    }
}

// MARK: - Presence decisions

/// Turns sonar readings and keyboard/trackpad activity into "someone is here" / "they left".
public struct PresenceTracker: Sendable {
    public enum Change: Equatable, Sendable { case left, returned }

    /// Motion reading above which someone counts as present (from the sonar test).
    public var threshold: Double
    /// How long without any sign of a person before they count as gone.
    public var awaySeconds: Double
    public private(set) var isPresent = true
    private var lastSeen: Double?

    public init(threshold: Double, awaySeconds: Double) {
        self.threshold = threshold
        self.awaySeconds = awaySeconds
    }

    public mutating func update(time: Double, motion: Double, recentInput: Bool) -> Change? {
        if lastSeen == nil { lastSeen = time }
        let seen = recentInput || motion > (isPresent ? threshold : threshold * 1.5)
        if seen { lastSeen = time }
        if isPresent, let last = lastSeen, time - last > awaySeconds {
            isPresent = false
            return .left
        }
        if !isPresent, seen {
            isPresent = true
            return .returned
        }
        return nil
    }
}

// MARK: - Test verdict

public struct SonarTestResult: Codable, Equatable, Sendable {
    public let works: Bool
    /// Suggested presence threshold (nil when it doesn't work).
    public let threshold: Double?
    /// How many times stronger the motion signal was with the person there than away.
    public let separation: Double
    public let toneLevel: Double
    /// Diagnostic numbers (you / empty room / hiss / clock drift).
    public var details: String?
    public let message: String

    /// Judges a test from readings taken while the user sat at the Mac and while they were away.
    public static func evaluate(present: [SonarAnalyzer.Reading], away: [SonarAnalyzer.Reading]) -> SonarTestResult {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let tone = median((present + away).map(\.toneLevel))
        let details = String(format: "You %.1e · empty room %.1e · hiss %.1e · clock drift %.2f Hz",
                             median(present.map(\.motion)), median(away.map(\.motion)),
                             median((present + away).map(\.hiss)), median((present + away).map(\.drift)))
        guard tone > 0.0005 else {
            return SonarTestResult(works: false, threshold: nil, separation: 0, toneLevel: tone,
                                   details: details, message: "The microphone couldn't hear the ultrasonic tone. Turn the volume up (at least 30%) and make sure sound comes from the Mac's own speakers, then try again. Some Macs can't play or hear tones this high.")
        }
        let here = median(present.map(\.motion))
        // With the hiss subtracted an empty room can read ~0, so cap the ratio at 100×.
        let empty = max(percentile(away.map(\.motion), 0.8), here * 0.01, 1e-12)
        let separation = here / empty
        guard separation >= 3 else {
            return SonarTestResult(works: false, threshold: nil, separation: separation, toneLevel: tone,
                                   details: details, message: String(format: "Sonar couldn't reliably tell you apart from an empty room (only %.1f× difference). Try again somewhere quieter, with nobody else moving nearby, and walk at least 3 metres away.", separation))
        }
        // Between the two, leaning towards "present" so it doesn't lock while you're there.
        let threshold = min((here * empty).squareRoot(), here * 0.5)
        return SonarTestResult(works: true, threshold: threshold, separation: separation, toneLevel: tone,
                               details: details, message: String(format: "Sonar works on your Mac: the signal was %.0f× stronger with you there than with the room empty.", separation))
    }
}

// MARK: - Settings

/// Sonar presence preferences.
public struct PresenceSettings: Codable, Equatable, Sendable {
    public var lockWhenAway = false
    public var awaySeconds = 30.0
    public var wakeOnReturn = true
    /// Result of the last sonar test on this Mac.
    public var testResult: SonarTestResult?

    public init() {}

    enum CodingKeys: String, CodingKey { case lockWhenAway, awaySeconds, wakeOnReturn, testResult }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lockWhenAway = (try? c.decodeIfPresent(Bool.self, forKey: .lockWhenAway)) ?? false
        awaySeconds = (try? c.decodeIfPresent(Double.self, forKey: .awaySeconds)) ?? 30
        wakeOnReturn = (try? c.decodeIfPresent(Bool.self, forKey: .wakeOnReturn)) ?? true
        testResult = (try? c.decodeIfPresent(SonarTestResult.self, forKey: .testResult)) ?? nil
    }

    /// Lock-when-away only runs after a successful sonar test.
    public var canLock: Bool { testResult?.works == true && testResult?.threshold != nil }
}

