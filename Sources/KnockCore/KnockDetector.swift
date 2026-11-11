import Foundation

/// Tuning knobs for the knock detector.
public struct DetectorParams: Equatable, Sendable {
    /// A frame's energy must exceed the running noise floor by this factor.
    public var onsetRatio: Double
    /// Minimum absolute peak amplitude (0…1) for a knock.
    public var minPeak: Float
    /// Energy must jump by this factor versus the previous frame (knocks have a sharp attack).
    public var attackRatio: Double = 4
    /// After `decayTime`, energy must have fallen below `peak * decayRatio` (knocks die out fast; speech/music don't).
    public var decayRatio: Double = 0.2
    public var decayTime: Double = 0.05
    /// Dead time after a knock onset so one knock is never counted twice.
    public var refractoryTime: Double = 0.1

    public init(onsetRatio: Double = 15, minPeak: Float = 0.05) {
        self.onsetRatio = onsetRatio
        self.minPeak = minPeak
    }

    /// Maps the user-facing 0…1 sensitivity slider to thresholds (geometric interpolation).
    public static func forSensitivity(_ sensitivity: Double) -> DetectorParams {
        let s = min(max(sensitivity, 0), 1)
        let ratio = 60 * pow(5.0 / 60.0, s)           // 60× … 5× above noise floor
        let peak = 0.25 * pow(0.01 / 0.25, s)         // 0.25 … 0.01 amplitude
        return DetectorParams(onsetRatio: ratio, minPeak: Float(peak))
    }
}

/// A detected knock plus a short multi-channel audio snippet starting just before its onset.
public struct KnockEvent: Sendable {
    public let peak: Float
    public let window: [[Float]]
    public let sampleRate: Double
}

/// Streaming transient detector. Feed it audio buffers; it returns knocks.
///
/// Algorithm (per ~5 ms frame):
/// 1. Track a slow-moving noise floor of frame energy.
/// 2. Onset = energy ≫ floor, peak above an absolute minimum, and a sudden jump from the previous frame.
/// 3. Confirm ~50 ms later that the energy has decayed (rejects speech, music, sustained noise).
/// Not thread-safe: call from one thread/queue.
public final class KnockDetector {
    public var params: DetectorParams
    public let sampleRate: Double
    public let channelCount: Int

    private let hop: Int
    private let ringSize: Int
    private var ring: [[Float]]
    private var written = 0

    private var frameFill = 0
    private var frameEnergy = 0.0
    private var framePeak: Float = 0

    private var noiseFloor = 1e-7
    private var previousEnergy = 1e-7
    private var levelSinceRead: Float = 0

    private enum State {
        case idle
        case confirming(onset: Int, peakEnergy: Double, peak: Float, framesLeft: Int)
        case refractory(until: Int)
    }
    private var state: State = .idle

    public init(sampleRate: Double, channelCount: Int, params: DetectorParams) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.params = params
        self.hop = max(32, Int(sampleRate * 0.005))
        self.ringSize = max(4096, Int(sampleRate * 0.5))
        self.ring = Array(repeating: Array(repeating: 0, count: ringSize), count: max(1, channelCount))
    }

    /// Highest frame RMS since the last call (for a level meter).
    public func takeLevel() -> Float {
        defer { levelSinceRead = 0 }
        return levelSinceRead
    }

    /// Process one buffer of non-interleaved samples (`channels[c][i]`).
    public func process(_ channels: [[Float]]) -> [KnockEvent] {
        guard let frames = channels.first?.count, frames > 0 else { return [] }
        let used = min(channelCount, channels.count)
        var events: [KnockEvent] = []

        for i in 0..<frames {
            let idx = written % ringSize
            var sumSquares = 0.0
            var peak: Float = 0
            for c in 0..<used {
                let v = channels[c][i]
                ring[c][idx] = v
                sumSquares += Double(v * v)
                peak = max(peak, abs(v))
            }
            if used < channelCount {
                for c in used..<channelCount { ring[c][idx] = 0 }
            }
            written += 1

            frameEnergy += sumSquares / Double(used)
            framePeak = max(framePeak, peak)
            frameFill += 1
            if frameFill == hop, let event = endFrame() {
                events.append(event)
            }
        }
        return events
    }

    private var hopSeconds: Double { Double(hop) / sampleRate }

    private func endFrame() -> KnockEvent? {
        let energy = frameEnergy / Double(hop)
        let peak = framePeak
        frameEnergy = 0
        framePeak = 0
        frameFill = 0
        levelSinceRead = max(levelSinceRead, Float(energy.squareRoot()))

        let frameStart = written - hop
        let decayFrames = max(1, Int((params.decayTime / hopSeconds).rounded(.up)))
        var result: KnockEvent?

        switch state {
        case .idle:
            if energy > noiseFloor * params.onsetRatio,
               peak >= params.minPeak,
               energy > previousEnergy * params.attackRatio {
                state = .confirming(onset: frameStart, peakEnergy: energy, peak: peak, framesLeft: decayFrames)
            } else {
                // Floor follows the ambient level with a ~1.5 s time constant.
                let alpha = min(1, hopSeconds / 1.5)
                noiseFloor = max(1e-10, noiseFloor + (energy - noiseFloor) * alpha)
            }

        case .confirming(let onset, let peakEnergy, let peakAmp, let framesLeft):
            let newPeakEnergy = max(peakEnergy, energy)
            let newPeak = max(peakAmp, peak)
            if framesLeft <= 1 {
                if energy < newPeakEnergy * params.decayRatio {
                    result = makeEvent(onset: onset, peak: newPeak)
                    state = .refractory(until: onset + Int(params.refractoryTime * sampleRate))
                } else {
                    // Sustained sound (speech, music…): not a knock. Raise the floor and back off.
                    noiseFloor += (energy - noiseFloor) * 0.3
                    state = .refractory(until: written + decayFrames * hop)
                }
            } else {
                state = .confirming(onset: onset, peakEnergy: newPeakEnergy, peak: newPeak, framesLeft: framesLeft - 1)
            }

        case .refractory(let until):
            if written >= until { state = .idle }
        }

        previousEnergy = max(energy, 1e-10)
        return result
    }

    private func makeEvent(onset: Int, peak: Float) -> KnockEvent {
        let start = max(0, onset - hop, written - ringSize)
        let available = written - start
        let maxLength = min(available, Int(sampleRate * 0.046))
        var length = 1
        while length * 2 <= maxLength { length *= 2 }

        var window: [[Float]] = []
        window.reserveCapacity(channelCount)
        for c in 0..<channelCount {
            var snippet = [Float](repeating: 0, count: length)
            for j in 0..<length { snippet[j] = ring[c][(start + j) % ringSize] }
            window.append(snippet)
        }
        return KnockEvent(peak: peak, window: window, sampleRate: sampleRate)
    }
}
