import Foundation

/// Tuning for Laptop Guard's "has someone moved the Mac?" check (motion sensor, values in g).
public struct MovementParams: Equatable, Sendable {
    /// Tilting the Mac by more than this many degrees from where it was when armed.
    public var tiltDegrees: Double = 6
    /// Sustained shaking (RMS of the jolt over ~0.3 s) above this level, e.g. being carried.
    public var shakeG: Double = 0.04
    /// Ignore the first moments after arming while the reading settles.
    public var settleTime: Double = 1.0

    public init() {}
}

public enum MovementReason: Equatable, Sendable {
    case tilted(degrees: Double)
    case shaken(g: Double)

    public var description: String {
        switch self {
        case .tilted(let degrees): return String(format: "Mac was moved (tilted %.0f°)", degrees)
        case .shaken: return "Mac was picked up or carried"
        }
    }
}

/// Detects the Mac being lifted, tilted or carried. A knock on the table or typing nearby is
/// too brief to count. Fires once, then stays quiet until `reset()`.
public final class MovementDetector {
    public var params: MovementParams

    private var start: Double?
    private var lastTime: Double?
    private var gravity: (x: Double, y: Double, z: Double)?
    private var baseline: (x: Double, y: Double, z: Double)?
    private var shakeEnergy = 0.0
    private var fired = false

    public init(params: MovementParams = MovementParams()) {
        self.params = params
    }

    public func reset() {
        start = nil
        lastTime = nil
        gravity = nil
        baseline = nil
        shakeEnergy = 0
        fired = false
    }

    public func process(t: Double, x: Double, y: Double, z: Double) -> MovementReason? {
        let dt: Double
        if let last = lastTime { dt = min(max(t - last, 0), 0.05) } else { dt = 0 }
        lastTime = t
        if start == nil { start = t }

        guard var g = gravity else {
            gravity = (x, y, z)
            return nil
        }
        // Gravity direction (~0.25 s low-pass) and the jolt on top of it.
        let alpha = dt > 0 ? 1 - exp(-dt / 0.25) : 0
        g.x += (x - g.x) * alpha
        g.y += (y - g.y) * alpha
        g.z += (z - g.z) * alpha
        gravity = g
        let dx = x - g.x, dy = y - g.y, dz = z - g.z
        let beta = dt > 0 ? 1 - exp(-dt / 0.3) : 0
        shakeEnergy += ((dx * dx + dy * dy + dz * dz) - shakeEnergy) * beta

        guard let started = start, t - started >= params.settleTime else { return nil }
        guard let base = baseline else {
            baseline = g
            return nil
        }
        guard !fired else { return nil }

        let gLen = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        let bLen = (base.x * base.x + base.y * base.y + base.z * base.z).squareRoot()
        if gLen > 0.1, bLen > 0.1 {
            let cosine = max(-1, min(1, (g.x * base.x + g.y * base.y + g.z * base.z) / (gLen * bLen)))
            let degrees = acos(cosine) * 180 / .pi
            if degrees > params.tiltDegrees {
                fired = true
                return .tilted(degrees: degrees)
            }
        }
        let shake = shakeEnergy.squareRoot()
        if shake > params.shakeG {
            fired = true
            return .shaken(g: shake)
        }
        return nil
    }
}
