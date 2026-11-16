import Foundation

// MARK: - Sonar analysis

/// Measures movement in front of the Mac from the echo of an inaudible tone.
///
/// The microphone signal is mixed down around the tone's frequency (like a Doppler radar): the static
/// echo from walls and furniture becomes a constant, while anything that moves (a person breathing,
/// shifting, typing) makes the echo's phase wobble. The wobble's energy relative to the tone's
/// strength is the "motion" reading, so it doesn't depend on volume. Breathing (~0.2–0.5 Hz) counts,
/// slow drifts below ~0.15 Hz don't. Not thread-safe: call from one queue.
public final class SonarAnalyzer {
    public struct Reading: Equatable, Sendable {
        /// Movement energy relative to the tone's strength (dimensionless).
        public let motion: Double
        /// Strength of the tone as heard by the microphone (amplitude, 0…1).
        public let toneLevel: Double
    }

    public let sampleRate: Double
    public let toneFrequency: Double

    // Oscillator as a rotating phasor (no trig per sample).
    private var oscRe = 1.0, oscIm = 0.0
    private let stepRe: Double, stepIm: Double
    private var renormalizeCounter = 0

    private var lowI1: Biquad, lowI2: Biquad, lowQ1: Biquad, lowQ2: Biquad
    private let decimation: Int
    private var blockCount = 0
    private var blockI = 0.0, blockQ = 0.0

    // Baseband (≈200 Hz): DC (static echo) tracking and motion accumulation.
    private let basebandRate: Double
    private var dcI = 0.0, dcQ = 0.0
    private var dcPrimed = false
    private let dcAlpha: Double
    private var motionSum = 0.0, toneSum = 0.0, readingCount = 0
    private let samplesPerReading: Int

    public init(sampleRate: Double, toneFrequency: Double = 19_500, readingsPerSecond: Double = 4) {
        self.sampleRate = sampleRate
        self.toneFrequency = toneFrequency
        let w = 2 * Double.pi * toneFrequency / sampleRate
        stepRe = cos(w)
        stepIm = -sin(w)
        lowI1 = .lowPass(cutoff: 120, sampleRate: sampleRate)
        lowI2 = .lowPass(cutoff: 120, sampleRate: sampleRate)
        lowQ1 = .lowPass(cutoff: 120, sampleRate: sampleRate)
        lowQ2 = .lowPass(cutoff: 120, sampleRate: sampleRate)
        decimation = max(1, Int(sampleRate / 200))
        basebandRate = sampleRate / Double(decimation)
        dcAlpha = 1 - exp(-2 * Double.pi * 0.15 / basebandRate)
        samplesPerReading = max(1, Int(basebandRate / readingsPerSecond))
    }

    public func process(_ samples: [Float]) -> [Reading] {
        var readings: [Reading] = []
        for sample in samples {
            let x = Double(sample)
            let i = lowI2.process(lowI1.process(x * oscRe))
            let q = lowQ2.process(lowQ1.process(x * oscIm))
            // Advance the oscillator.
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

            blockI += i
            blockQ += q
            blockCount += 1
            guard blockCount == decimation else { continue }
            let bi = blockI / Double(decimation), bq = blockQ / Double(decimation)
            blockI = 0
            blockQ = 0
            blockCount = 0
            if let reading = baseband(bi, bq) { readings.append(reading) }
        }
        return readings
    }

    private func baseband(_ i: Double, _ q: Double) -> Reading? {
        if !dcPrimed {
            dcI = i
            dcQ = q
            dcPrimed = true
        }
        dcI += (i - dcI) * dcAlpha
        dcQ += (q - dcQ) * dcAlpha
        let hi = i - dcI, hq = q - dcQ
        motionSum += hi * hi + hq * hq
        toneSum += i * i + q * q
        readingCount += 1
        guard readingCount == samplesPerReading else { return nil }
        let motion = motionSum / Double(readingCount)
        let tone = toneSum / Double(readingCount)
        motionSum = 0
        toneSum = 0
        readingCount = 0
        // Mixing halves the amplitude; ×2 gives the tone's amplitude in the microphone signal.
        return Reading(motion: tone > 0 ? motion / tone : 0, toneLevel: 2 * tone.squareRoot())
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
        guard tone > 0.0005 else {
            return SonarTestResult(works: false, threshold: nil, separation: 0, toneLevel: tone,
                                   message: "The microphone couldn't hear the ultrasonic tone. Turn the volume up (at least 30%) and make sure sound comes from the Mac's own speakers, then try again. Some Macs can't play or hear tones this high.")
        }
        let here = median(present.map(\.motion))
        let empty = max(percentile(away.map(\.motion), 0.8), 1e-12)
        let separation = here / empty
        guard separation >= 3 else {
            return SonarTestResult(works: false, threshold: nil, separation: separation, toneLevel: tone,
                                   message: String(format: "Sonar couldn't reliably tell you apart from an empty room (only %.1f× difference). Try again somewhere quieter, with nobody else moving nearby, and walk at least 3 metres away.", separation))
        }
        // Between the two, leaning towards "present" so it doesn't lock while you're there.
        let threshold = min((here * empty).squareRoot(), here * 0.5)
        return SonarTestResult(works: true, threshold: threshold, separation: separation, toneLevel: tone,
                               message: String(format: "Sonar works on your Mac: the signal was %.0f× stronger with you there than with the room empty.", separation))
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

