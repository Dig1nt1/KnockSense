import Foundation

/// Tuning for detecting knocks from the MacBook's motion sensor (accelerometer, values in g).
public struct TapParams: Equatable, Sendable {
    /// Minimum jolt (deviation from gravity), in g.
    public var minPeak: Double
    /// The jolt must exceed the background vibration level by this factor.
    public var backgroundRatio: Double = 5
    /// …and the loudest moment of the preceding `attackWindow` (ignoring the last few ms) by this factor.
    public var attackRatio: Double = 3
    public var attackWindow: Double = 0.025
    /// Time after onset in which the peak is searched.
    public var peakWindow: Double = 0.012
    /// Between `tailStart` and `tailEnd` after onset, the average jolt must have dropped below
    /// `peak * decayRatio` (a knock rings out fast; carrying or bumping the Mac doesn't).
    public var tailStart: Double = 0.025
    public var tailEnd: Double = 0.05
    public var decayRatio: Double = 0.35
    public var refractoryTime: Double = 0.08

    public init(minPeak: Double = 0.03) {
        self.minPeak = minPeak
    }

    /// Maps the 0…1 sensitivity slider: 0.12 g (firm knocks only) … 0.008 g (light taps).
    public static func forSensitivity(_ sensitivity: Double) -> TapParams {
        let s = min(max(sensitivity, 0), 1)
        return TapParams(minPeak: 0.12 * pow(0.008 / 0.12, s))
    }
}

public struct TapEvent: Equatable, Sendable {
    /// Peak jolt in g.
    public let peak: Double
    /// Unit vector of the jolt at its peak (which way the knock pushed the Mac). Used to tell areas apart.
    public let direction: [Double]
    public let time: Double

    /// Fingerprint for area classification (3 values: the jolt direction).
    public var features: [Double] { direction }
}

/// Streaming knock detector for accelerometer samples (timestamps in seconds, acceleration in g).
/// Not thread-safe: call from one queue.
public final class TapDetector {
    public var params: TapParams

    private var gravity: (x: Double, y: Double, z: Double)?
    private var lastTime: Double?
    private var background = 0.002
    /// Recent (time, magnitude) pairs for the attack test.
    private var recent: [(t: Double, m: Double)] = []

    private struct Candidate {
        var onset: Double
        var pre: Double
        var peak: Double
        var direction: [Double]
        var tailSum = 0.0
        var tailCount = 0
    }
    private var candidate: Candidate?
    private var refractoryUntil = -Double.infinity
    private var levelSinceRead = 0.0

    public init(params: TapParams) {
        self.params = params
    }

    /// Highest jolt (g) since the last call, for a level meter.
    public func takeLevel() -> Double {
        defer { levelSinceRead = 0 }
        return levelSinceRead
    }

    public func process(t: Double, x: Double, y: Double, z: Double) -> TapEvent? {
        let dt: Double
        if let last = lastTime { dt = min(max(t - last, 0), 0.05) } else { dt = 0 }
        lastTime = t

        // Gravity / slow motion estimate (~50 ms low-pass). Whatever is left is the jolt.
        guard var g = gravity else {
            gravity = (x, y, z)
            return nil
        }
        let alpha = dt > 0 ? 1 - exp(-dt / 0.05) : 0
        g.x += (x - g.x) * alpha
        g.y += (y - g.y) * alpha
        g.z += (z - g.z) * alpha
        gravity = g
        let dx = x - g.x, dy = y - g.y, dz = z - g.z
        let m = (dx * dx + dy * dy + dz * dz).squareRoot()
        levelSinceRead = max(levelSinceRead, m)

        defer {
            recent.append((t, m))
            let cutoff = t - params.attackWindow - 0.01
            if let firstKeep = recent.firstIndex(where: { $0.t >= cutoff }), firstKeep > 0 {
                recent.removeFirst(firstKeep)
            }
        }

        if var c = candidate {
            let age = t - c.onset
            if age <= params.peakWindow, m > c.peak {
                c.peak = m
                c.direction = [dx / m, dy / m, dz / m]
            }
            if age >= params.tailStart && age <= params.tailEnd {
                c.tailSum += m
                c.tailCount += 1
            }
            if age > params.tailEnd {
                candidate = nil
                let tail = c.tailCount > 0 ? c.tailSum / Double(c.tailCount) : 0
                if tail < max(c.peak * params.decayRatio, c.pre * 2) {
                    refractoryUntil = c.onset + params.refractoryTime
                    return TapEvent(peak: c.peak, direction: c.direction, time: c.onset)
                }
                // Kept shaking (carried, bumped, music through the desk…): not a knock.
                return nil
            }
            candidate = c
            return nil
        }

        guard t >= refractoryUntil else { return nil }

        // Loudest moment of the attack window, excluding the last 4 ms (the tap's own rising edge).
        let windowStart = t - params.attackWindow, windowEnd = t - 0.004
        let pre = recent.filter { $0.t >= windowStart && $0.t <= windowEnd }.map(\.m).max() ?? 0

        if m >= params.minPeak, m > background * params.backgroundRatio, m > pre * params.attackRatio {
            candidate = Candidate(onset: t, pre: pre, peak: m, direction: [dx / m, dy / m, dz / m])
        } else {
            // Background vibration level (~1 s time constant), only while nothing is happening.
            let beta = dt > 0 ? 1 - exp(-dt / 1.0) : 0
            background = max(0.0005, background + (m - background) * beta)
        }
        return nil
    }
}
