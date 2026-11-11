import AVFoundation
import Foundation

/// A loud, looping two-tone siren generated in code (no sound files needed).
final class Siren {
    private var player: AVAudioPlayer?

    func start() {
        if player == nil {
            player = try? AVAudioPlayer(data: Self.makeWAV())
            player?.numberOfLoops = -1
            player?.volume = 1
            player?.prepareToPlay()
        }
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// 1 s of a sweeping siren (650 → 1550 → 650 Hz) as 16-bit mono PCM WAV.
    private static func makeWAV() -> Data {
        let rate = 44_100
        let count = rate
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let sweep = t < 0.5 ? t / 0.5 : (1 - t) / 0.5             // up then down
            let frequency = 650 + 900 * sweep
            phase += 2 * Double.pi * frequency / Double(rate)
            // Slightly squared-off sine: louder and harsher, like a real alarm.
            let value = max(-1, min(1, sin(phase) * 1.6)) * 0.9
            samples[i] = Int16(value * Double(Int16.max))
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }
}
