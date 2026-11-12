import Foundation

// MARK: - Zone classification

public struct Classification: Equatable, Sendable {
    public let zoneID: UUID
    /// Share of the weighted nearest-neighbour vote (0…1).
    public let confidence: Double
}

/// k-nearest-neighbour classifier over z-score-normalised fingerprints.
public enum ZoneClassifier {
    public static func classify(_ features: [Double], zones: [Zone], k: Int = 3) -> Classification? {
        guard !features.isEmpty else { return nil }
        var training: [(zone: UUID, vector: [Double])] = []
        for zone in zones {
            for sample in zone.samples where sample.count == features.count {
                training.append((zone.id, sample))
            }
        }
        guard !training.isEmpty else { return nil }

        let dim = features.count
        var mean = [Double](repeating: 0, count: dim)
        for t in training { for d in 0..<dim { mean[d] += t.vector[d] } }
        for d in 0..<dim { mean[d] /= Double(training.count) }
        var std = [Double](repeating: 0, count: dim)
        for t in training { for d in 0..<dim { std[d] += pow(t.vector[d] - mean[d], 2) } }
        for d in 0..<dim { std[d] = max(0.05, (std[d] / Double(training.count)).squareRoot()) }

        func distance(_ v: [Double]) -> Double {
            var sum = 0.0
            for d in 0..<dim {
                let diff = (v[d] - features[d]) / std[d]
                sum += diff * diff
            }
            return sum.squareRoot()
        }

        let neighbours = training
            .map { (zone: $0.zone, distance: distance($0.vector)) }
            .sorted { $0.distance < $1.distance }
            .prefix(max(1, k))

        var votes: [UUID: Double] = [:]
        for n in neighbours { votes[n.zone, default: 0] += 1 / (n.distance + 1e-3) }
        let total = votes.values.reduce(0, +)
        guard let best = votes.max(by: { $0.value < $1.value }), total > 0 else { return nil }
        return Classification(zoneID: best.key, confidence: best.value / total)
    }

    /// Leave-one-out accuracy over the training samples: a quick "how distinguishable are my zones?" score.
    /// Returns nil unless at least two zones have samples.
    public static func selfTestAccuracy(zones: [Zone]) -> Double? {
        guard zones.filter({ !$0.samples.isEmpty }).count >= 2 else { return nil }
        var correct = 0, total = 0
        for (zi, zone) in zones.enumerated() {
            for si in zone.samples.indices {
                var reduced = zones
                let sample = reduced[zi].samples.remove(at: si)
                guard let result = classify(sample, zones: reduced) else { continue }
                total += 1
                if result.zoneID == zone.id { correct += 1 }
            }
        }
        return total > 0 ? Double(correct) / Double(total) : nil
    }
}

// MARK: - Knock patterns (single, double, triple…)

public struct KnockPattern: Equatable, Sendable {
    public let count: Int
    /// Majority zone of the knocks in the pattern (nil when unknown).
    public let zoneID: UUID?
}

/// Groups individual knocks into patterns: knocks closer together than `gap` belong together.
public final class PatternGrouper {
    public var gap: TimeInterval
    /// When a pattern reaches this many knocks it fires immediately (no waiting for the gap).
    public var maxCount: Int

    private var zones: [UUID?] = []
    private var lastTime: TimeInterval = 0

    public init(gap: TimeInterval = 0.45, maxCount: Int = 4) {
        self.gap = gap
        self.maxCount = maxCount
    }

    public var pendingCount: Int { zones.count }

    public func add(at time: TimeInterval, zone: UUID?) -> [KnockPattern] {
        var emitted: [KnockPattern] = []
        if !zones.isEmpty, time - lastTime > gap { emitted.append(flush()) }
        zones.append(zone)
        lastTime = time
        if zones.count >= max(1, maxCount) { emitted.append(flush()) }
        return emitted
    }

    /// Call periodically; returns a pattern once the gap after the last knock has elapsed.
    public func poll(now: TimeInterval) -> KnockPattern? {
        guard !zones.isEmpty, now - lastTime > gap else { return nil }
        return flush()
    }

    public func reset() { zones = [] }

    private func flush() -> KnockPattern {
        var counts: [UUID?: Int] = [:]
        for z in zones { counts[z, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        let majority = zones.first { counts[$0] == top } ?? nil
        let pattern = KnockPattern(count: zones.count, zoneID: majority)
        zones = []
        return pattern
    }
}

// MARK: - Rule matching

public enum RuleMatcher {
    /// Picks the most specific matching rules. A rule for the app in front beats an "any app" rule,
    /// and a rule for the knocked area beats an "anywhere" rule (app first, then area).
    public static func match(_ pattern: KnockPattern, rules: [Rule], frontmostApp: String? = nil) -> [Rule] {
        var best: [Rule] = []
        var bestScore = -1
        for rule in rules where rule.enabled && rule.knockCount == pattern.count {
            if let zone = rule.zoneID, zone != pattern.zoneID { continue }
            if let app = rule.appBundleID, app.caseInsensitiveCompare(frontmostApp ?? "") != .orderedSame { continue }
            let score = (rule.appBundleID != nil ? 2 : 0) + (rule.zoneID != nil ? 1 : 0)
            if score > bestScore {
                best = [rule]
                bestScore = score
            } else if score == bestScore {
                best.append(rule)
            }
        }
        return best
    }

    public static func maxKnockCount(in rules: [Rule]) -> Int {
        max(1, rules.filter(\.enabled).map(\.knockCount).max() ?? 1)
    }
}
