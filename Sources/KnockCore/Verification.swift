import Foundation

/// One detected sound: its fingerprint and peak loudness.
public struct SoundSample: Equatable, Sendable {
    public let features: [Double]
    public let peak: Float

    public init(features: [Double], peak: Float) {
        self.features = features
        self.peak = peak
    }
}

/// A deliberate knock pattern is made of knocks that sound alike. Everyday sounds that happen to
/// produce two sharp hits close together — a door's latch click followed by the door hitting the
/// frame, footsteps, a dropped object bouncing — usually don't.
public enum PatternConsistency {
    /// Minimum correlation between the spectral shapes of the knocks in a pattern.
    public static let minimumShapeCorrelation = 0.6
    /// Maximum loudness difference between the loudest and quietest knock (12 dB).
    public static let maximumPeakRatio: Float = 4

    public static func isConsistent(_ knocks: [SoundSample]) -> Bool {
        guard knocks.count >= 2 else { return true }
        let peaks = knocks.map(\.peak)
        if let lo = peaks.min(), let hi = peaks.max(), lo > 0, hi / lo > maximumPeakRatio { return false }
        // Tone shape only exists for microphone fingerprints; motion-sensor knocks are checked on
        // loudness alone (a door can't shake the Mac anyway).
        guard knocks.allSatisfy({ $0.features.count >= FeatureExtractor.bandCount }) else { return true }
        let shapes = knocks.map { Array($0.features.prefix(FeatureExtractor.bandCount)) }
        for i in 0..<shapes.count {
            for j in (i + 1)..<shapes.count where correlation(shapes[i], shapes[j]) < minimumShapeCorrelation {
                return false
            }
        }
        return true
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n >= 2 else { return 1 }
        let ma = a.prefix(n).reduce(0, +) / Double(n)
        let mb = b.prefix(n).reduce(0, +) / Double(n)
        var num = 0.0, da = 0.0, db = 0.0
        for k in 0..<n {
            num += (a[k] - ma) * (b[k] - mb)
            da += (a[k] - ma) * (a[k] - ma)
            db += (b[k] - mb) * (b[k] - mb)
        }
        guard da > 0, db > 0 else { return 1 }
        return num / (da * db).squareRoot()
    }
}

/// Checks a detected sound against the user's trained knocks ("Teach my knock" and area training)
/// and against sounds the user marked as "That wasn't me".
public enum KnockVerifier {
    public enum Verdict: Equatable, Sendable {
        case accepted
        /// Not enough training yet to judge; the sound is let through.
        case notTrained
        case notLikeYourKnock
        case markedAsNotAKnock
        case tooQuiet
    }

    /// Trained knocks needed before verification switches on.
    public static let minimumSamples = 4
    /// A knock must be at least this fraction of your typical trained knock's loudness (about −12 dB).
    public static let minimumRelativePeak = 0.25
    /// Bounds for the tone-shape similarity a sound needs to count as your knock.
    public static let similarityFloor = 0.5
    public static let similarityCeiling = 0.8

    /// Compares the sound's tone shape (the loudness-normalised frequency bands) with your trained
    /// knocks. Tone shape survives background noise well, so knocks during a movie still match, while a
    /// door, footsteps or a clap have a clearly different shape.
    public static func verify(_ sound: SoundSample, knocks: [SoundSample], rejected: [[Double]]) -> Verdict {
        let dim = sound.features.count
        let positives = knocks.filter { $0.features.count == dim }
        guard dim >= FeatureExtractor.bandCount, positives.count >= minimumSamples else { return .notTrained }

        let peaks = positives.map { Double($0.peak) }.filter { $0 > 0 }.sorted()
        if !peaks.isEmpty, Double(sound.peak) < peaks[peaks.count / 2] * minimumRelativePeak {
            return .tooQuiet
        }

        func shape(_ v: [Double]) -> [Double] { Array(v.prefix(FeatureExtractor.bandCount)) }
        let query = shape(sound.features)
        let trained = positives.map { shape($0.features) }

        let knockSimilarity = trained.map { PatternConsistency.correlation($0, query) }.max() ?? -1
        let rejectSimilarity = rejected
            .filter { $0.count == dim }
            .map { PatternConsistency.correlation(shape($0), query) }
            .max() ?? -1
        if rejectSimilarity > knockSimilarity { return .markedAsNotAKnock }

        // How alike the user's own knocks are: each one's best match among the others.
        var bestMatches: [Double] = []
        for (i, a) in trained.enumerated() {
            var best = -1.0
            for (j, b) in trained.enumerated() where i != j { best = max(best, PatternConsistency.correlation(a, b)) }
            bestMatches.append(best)
        }
        bestMatches.sort()
        let typical = bestMatches[bestMatches.count / 10]      // 10th percentile: allow for variation
        let threshold = min(similarityCeiling, max(similarityFloor, typical - 0.15))
        return knockSimilarity >= threshold ? .accepted : .notLikeYourKnock
    }
}
