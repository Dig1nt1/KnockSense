import Foundation

/// Turns a knock's audio snippet into a fixed-length "fingerprint" used to tell knock locations apart.
///
/// Different spots on the chassis resonate differently and reach each built-in microphone with a
/// different level/delay, so we capture:
/// * spectral shape: 16 log-spaced band energies (loudness-normalised)
/// * spectral centroid and decay speed
/// * per-microphone level differences and the inter-mic time delay (when >1 channel is available)
public enum FeatureExtractor {
    public static let bandCount = 16

    public static func extract(_ event: KnockEvent) -> [Double] {
        extract(window: event.window, sampleRate: event.sampleRate)
    }

    public static func extract(window: [[Float]], sampleRate: Double) -> [Double] {
        guard let n = window.first?.count, n >= 64, sampleRate > 0 else { return [] }
        let channels = Array(window.prefix(4))

        // Average power spectrum across microphones (avoids phase cancellation of a mono mix).
        var power = [Double](repeating: 0, count: n / 2 + 1)
        for ch in channels {
            let p = FFT.powerSpectrum(taper(ch))
            for k in power.indices { power[k] += p[k] }
        }

        let binHz = sampleRate / Double(n)
        let fLow = 60.0
        let fHigh = min(16_000.0, sampleRate * 0.475)
        var bands: [Double] = []
        for b in 0..<bandCount {
            let f0 = fLow * pow(fHigh / fLow, Double(b) / Double(bandCount))
            let f1 = fLow * pow(fHigh / fLow, Double(b + 1) / Double(bandCount))
            let k0 = min(power.count - 1, max(1, Int(f0 / binHz)))
            let k1 = min(power.count, max(k0 + 1, Int(f1 / binHz)))
            var e = 0.0
            for k in k0..<k1 { e += power[k] }
            bands.append(log10(e + 1e-12))
        }
        let meanBand = bands.reduce(0, +) / Double(bandCount)
        var features = bands.map { $0 - meanBand }

        // Spectral centroid (log2 Hz, centred on 1 kHz).
        var num = 0.0, den = 0.0
        for k in 1..<power.count {
            num += log2(Double(k) * binHz) * power[k]
            den += power[k]
        }
        features.append(den > 0 ? num / den - log2(1000) : 0)

        // Decay: energy of the second half relative to the first half.
        let half = n / 2
        var first = 0.0, second = 0.0
        for ch in channels {
            for i in 0..<half { first += Double(ch[i] * ch[i]) }
            for i in half..<n { second += Double(ch[i] * ch[i]) }
        }
        features.append(log10((second + 1e-12) / (first + 1e-12)))

        // Spatial cues from the microphone array.
        if channels.count >= 2 {
            let levels = channels.map { ch in log10(ch.reduce(0.0) { $0 + Double($1 * $1) } + 1e-12) }
            let meanLevel = levels.reduce(0, +) / Double(levels.count)
            features += levels.map { $0 - meanLevel }
            let maxLag = max(1, Int(sampleRate * 0.0006))
            features.append(crossCorrelationLag(channels[0], channels[1], maxLag: maxLag))
        }
        return features
    }

    /// Short fade-in, half-cosine fade-out over the last quarter. Keeps the attack intact (unlike Hann).
    static func taper(_ x: [Float]) -> [Float] {
        let n = x.count
        var y = x
        let fadeIn = min(32, n / 8)
        for i in 0..<fadeIn { y[i] *= Float(i) / Float(fadeIn) }
        let fadeOutStart = n - n / 4
        for i in fadeOutStart..<n {
            let t = Double(i - fadeOutStart) / Double(n - fadeOutStart)
            y[i] *= Float(0.5 * (1 + cos(Double.pi * t)))
        }
        return y
    }

    /// Lag (normalised to −1…1) that maximises the cross-correlation of `a` and `b`.
    static func crossCorrelationLag(_ a: [Float], _ b: [Float], maxLag: Int) -> Double {
        let n = min(a.count, b.count)
        var bestLag = 0
        var best = -Double.infinity
        for lag in -maxLag...maxLag {
            var sum = 0.0
            let lo = max(0, -lag), hi = min(n, n - lag)
            var i = lo
            while i < hi {
                sum += Double(a[i] * b[i + lag])
                i += 1
            }
            if sum > best { best = sum; bestLag = lag }
        }
        return Double(bestLag) / Double(maxLag)
    }
}

enum FFT {
    /// In-place iterative radix-2 FFT. `re.count` must be a power of two.
    static func transform(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1 else { return }
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let angle = -2 * Double.pi / Double(len)
            let wRe = cos(angle), wIm = sin(angle)
            let halfLen = len / 2
            var start = 0
            while start < n {
                var cRe = 1.0, cIm = 0.0
                for k in 0..<halfLen {
                    let a = start + k, b = a + halfLen
                    let tRe = re[b] * cRe - im[b] * cIm
                    let tIm = re[b] * cIm + im[b] * cRe
                    re[b] = re[a] - tRe
                    im[b] = im[a] - tIm
                    re[a] += tRe
                    im[a] += tIm
                    let next = cRe * wRe - cIm * wIm
                    cIm = cRe * wIm + cIm * wRe
                    cRe = next
                }
                start += len
            }
            len <<= 1
        }
    }

    /// One-sided power spectrum (n/2 + 1 bins).
    static func powerSpectrum(_ x: [Float]) -> [Double] {
        var re = x.map(Double.init)
        var im = [Double](repeating: 0, count: x.count)
        transform(&re, &im)
        return (0...(x.count / 2)).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }
}
