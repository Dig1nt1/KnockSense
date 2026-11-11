import Foundation

/// Tuning knobs for the knock detector.
public struct DetectorParams: Equatable, Sendable {
    /// A frame's energy must exceed the background (median of the last ~0.3 s) by this factor.
    public var onsetRatio: Double
    /// Minimum absolute peak amplitude (0…1) for a knock.
    public var minPeak: Float
    /// Energy must jump by this factor versus the loudest frame of the preceding `attackWindow`
    /// (knocks are new energy out of nowhere; a word's pitch flicker or a swelling note is not).
    public var attackRatio: Double = 3
    public var attackWindow: Double = 0.02
    /// The average energy of the tail (from `tailStart` to `decayTime` after the onset) must be below
    /// `peak * decayRatio`: knocks die out within ~15 ms, words and notes keep going.
    public var decayRatio: Double = 0.3
    /// …or the tail must be back near what was playing just before the knock (loudest frame of the
    /// preceding `attackWindow`), so a knock on top of a movie still counts. A word or note that
    /// *starts* leaves the sound louder than before and is rejected.
    public var backgroundReturnRatio: Double = 2
    public var tailStart: Double = 0.02
    public var decayTime: Double = 0.05
    /// Dead time after a knock onset so one knock is never counted twice.
    public var refractoryTime: Double = 0.1

    public init(onsetRatio: Double = 8, minPeak: Float = 0.05) {
        self.onsetRatio = onsetRatio
        self.minPeak = minPeak
    }

    /// Maps the user-facing 0…1 sensitivity slider to thresholds (geometric interpolation).
    public static func forSensitivity(_ sensitivity: Double) -> DetectorParams {
        let s = min(max(sensitivity, 0), 1)
        let ratio = 30 * pow(3.0 / 30.0, s)           // 30× … 3× above background energy
        let peak = 0.25 * pow(0.01 / 0.25, s)         // 0.25 … 0.01 amplitude
        return DetectorParams(onsetRatio: ratio, minPeak: Float(peak))
    }
}

/// A detected knock plus a short multi-channel audio snippet starting just before its onset.
public struct KnockEvent: Sendable {
    public let peak: Float
    public let window: [[Float]]
    public let sampleRate: Double
    /// Diagnostics: sample index of the onset and the frequency band that triggered (0 = full band).
    public var onsetSample = 0
    public var band = 0
    public var ratio = 0.0
}

/// Streaming transient detector. Feed it audio buffers; it returns knocks.
///
/// The signal is analysed in several frequency bands at once (full band plus four band-pass bands).
/// A knock is a broadband click, so even when a movie or music fills the low/mid frequencies, the knock
/// still stands out clearly in the bands the soundtrack leaves quieter.
///
/// Per band and per ~5 ms frame:
/// 1. Background = median energy of the last ~0.3 s. The median ignores short spikes and follows
///    whatever is playing (silence, a movie, music) within a fraction of a second.
/// 2. Onset = in some band, energy ≫ background and a sudden jump from the previous frame; plus an
///    overall peak above the absolute minimum.
/// 3. ~50 ms later, that band must have died away — to a small fraction of its peak, or back to its
///    pre-knock background. Rejects speech and other sounds that keep going.
/// Not thread-safe: call from one thread/queue.
public final class KnockDetector {
    public var params: DetectorParams
    public let sampleRate: Double
    public let channelCount: Int

    /// Band-pass centre frequencies analysed in addition to the full band.
    static let bandCentres: [Double] = [250, 800, 2000, 5000]

    private let hop: Int
    private let ringSize: Int
    private var ring: [[Float]]
    private var written = 0

    private var filters: [Biquad]
    private let bandCount: Int
    private var frameFill = 0
    private var frameEnergy: [Double]
    private var framePeak: Float = 0

    private var history: [[Double]]          // [band][frame]
    private var historyIndex = 0
    private var historyCount = 0
    private var recentEnergy: [[Double]]     // [band][last few frames], for the attack test
    private var recentIndex = 0
    private var levelSinceRead: Float = 0

    private struct Candidate {
        var onset: Int
        var band: Int
        var ratio: Double
        var background: Double
        var peakEnergy: Double
        var fullBackground: Double
        var preBand: Double
        var preFull: Double
        var fullPeakEnergy: Double
        var peak: Float
        var framesLeft: Int
        var tailBand = 0.0
        var tailFull = 0.0
        var tailFrames = 0
    }

    private enum State {
        case idle
        case confirming(Candidate)
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
        self.filters = Self.bandCentres
            .filter { $0 < sampleRate * 0.42 }
            .map { Biquad.bandPass(centre: $0, q: 0.9, sampleRate: sampleRate) }
        self.bandCount = filters.count + 1     // band 0 = full band
        self.frameEnergy = Array(repeating: 0, count: bandCount)
        let attackFrames = max(1, Int((params.attackWindow * sampleRate / Double(hop)).rounded()))
        self.recentEnergy = Array(repeating: Array(repeating: 1e-7, count: attackFrames), count: bandCount)
        let historyLength = max(16, Int(0.3 * sampleRate) / hop)
        self.history = Array(repeating: Array(repeating: 0, count: historyLength), count: bandCount)
    }

    /// Current full-band background energy estimate (median of recent non-knock frames).
    public var backgroundEnergy: Double { background(band: 0) }

    private func background(band: Int) -> Double {
        guard historyCount > 0 else { return 1e-7 }
        let recent = history[band].prefix(historyCount).sorted()
        return max(1e-12, recent[recent.count / 2])
    }

    private func remember(_ energies: [Double]) {
        for b in 0..<bandCount { history[b][historyIndex] = energies[b] }
        historyIndex = (historyIndex + 1) % history[0].count
        historyCount = min(historyCount + 1, history[0].count)
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
            var sum: Float = 0
            var sumSquares = 0.0
            var peak: Float = 0
            for c in 0..<used {
                let v = channels[c][i]
                ring[c][idx] = v
                sum += v
                sumSquares += Double(v * v)
                peak = max(peak, abs(v))
            }
            if used < channelCount {
                for c in used..<channelCount { ring[c][idx] = 0 }
            }
            written += 1

            frameEnergy[0] += sumSquares / Double(used)
            let mono = Double(sum) / Double(used)
            for f in filters.indices {
                let y = filters[f].process(mono)
                frameEnergy[f + 1] += y * y
            }
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
        let energies = frameEnergy.map { max($0 / Double(hop), 1e-14) }
        let peak = framePeak
        for b in 0..<bandCount { frameEnergy[b] = 0 }
        framePeak = 0
        frameFill = 0
        levelSinceRead = max(levelSinceRead, Float(energies[0].squareRoot()))

        let frameStart = written - hop
        let decayFrames = max(1, Int((params.decayTime / hopSeconds).rounded(.up)))
        var result: KnockEvent?

        switch state {
        case .idle:
            if let candidate = onsetCandidate(energies: energies, peak: peak, frameStart: frameStart, decayFrames: decayFrames) {
                state = .confirming(candidate)
            } else {
                remember(energies)
            }

        case .confirming(var candidate):
            let newer = onsetCandidate(energies: energies, peak: peak, frameStart: frameStart, decayFrames: decayFrames)
            if let newer, newer.ratio > candidate.ratio * 1.5 {
                // A much sharper hit landed while we were checking a softer sound (e.g. a knock right
                // after a word in a movie): judge the new hit instead.
                state = .confirming(newer)
            } else {
                let e = energies[candidate.band]
                let full = energies[0]
                candidate.peakEnergy = max(candidate.peakEnergy, e)
                candidate.fullPeakEnergy = max(candidate.fullPeakEnergy, full)
                candidate.peak = max(candidate.peak, peak)
                candidate.framesLeft -= 1
                if Double(frameStart - candidate.onset) >= params.tailStart * sampleRate {
                    candidate.tailBand += e
                    candidate.tailFull += full
                    candidate.tailFrames += 1
                }
                if candidate.framesLeft <= 0 {
                    // Both the band that triggered and the overall sound must have died away quickly:
                    // a word or note keeps going, a knock over a movie drops back to the movie.
                    let frames = Double(max(1, candidate.tailFrames))
                    let tailBand = candidate.tailBand / frames
                    let tailFull = candidate.tailFull / frames
                    let bandFaded = tailBand < max(candidate.peakEnergy * params.decayRatio,
                                                   candidate.preBand * params.backgroundReturnRatio)
                    let fullFaded = tailFull < max(candidate.fullPeakEnergy * params.decayRatio,
                                                   candidate.preFull * params.backgroundReturnRatio)
                    let faded = bandFaded && fullFaded
                    if faded {
                        result = makeEvent(onset: candidate.onset, peak: candidate.peak)
                        result?.onsetSample = candidate.onset
                        result?.band = candidate.band
                        result?.ratio = candidate.ratio
                        state = .refractory(until: candidate.onset + Int(params.refractoryTime * sampleRate))
                    } else {
                        // Sound kept going (speech, music…): not a knock. Resume listening immediately —
                        // the attack test stops a sustained sound from re-triggering.
                        state = .idle
                        remember(energies)
                    }
                } else {
                    state = .confirming(candidate)
                }
            }

        case .refractory(let until):
            if written >= until { state = .idle }
        }

        for b in 0..<bandCount { recentEnergy[b][recentIndex] = energies[b] }
        recentIndex = (recentIndex + 1) % recentEnergy[0].count
        return result
    }

    /// The band in which this frame most clearly looks like the start of a knock, if any.
    private func onsetCandidate(energies: [Double], peak: Float, frameStart: Int, decayFrames: Int) -> Candidate? {
        guard peak >= params.minPeak else { return nil }
        var best: Candidate?
        let fullBackground = background(band: 0)
        let preFull = recentEnergy[0].max() ?? 0
        for b in 0..<bandCount {
            let bg = background(band: b)
            let ratio = energies[b] / bg
            let pre = recentEnergy[b].max() ?? 0
            guard ratio > params.onsetRatio,
                  energies[b] > pre * params.attackRatio,
                  ratio > (best?.ratio ?? 0) else { continue }
            best = Candidate(onset: frameStart, band: b, ratio: ratio, background: bg,
                             peakEnergy: energies[b], fullBackground: fullBackground,
                             preBand: pre, preFull: preFull,
                             fullPeakEnergy: energies[0], peak: peak, framesLeft: decayFrames)
        }
        return best
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

/// Second-order IIR filter (RBJ audio-EQ cookbook), transposed direct form II.
struct Biquad {
    private let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Band-pass with 0 dB peak gain at `centre`.
    static func bandPass(centre: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * centre / sampleRate
        let alpha = sin(w0) / (2 * q)
        return Biquad(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cos(w0), a2: 1 - alpha)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
