import AVFoundation
import Foundation

/// Plays the inaudible sonar tone through the Mac's **built-in speakers** (even when headphones are
/// connected), fading in and out so it never clicks.
final class SonarEmitter: @unchecked Sendable {
    static let frequency = 19_500.0

    private var engine: AVAudioEngine?
    private let tone = ToneGenerator()
    private(set) var isRunning = false

    func start(level: Float = 0.25) throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        if let speakers = AudioDevices.builtInSpeakers(), let unit = engine.outputNode.audioUnit {
            AudioDevices.setInputDevice(speakers, on: unit)     // same property selects an output device
        }
        let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = deviceRate > 0 ? deviceRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        tone.configure(sampleRate: sampleRate, frequency: Self.frequency, level: level)
        let generator = tone
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            generator.render(into: UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    func stop() {
        guard let engine else { return }
        tone.fadeOut()
        self.engine = nil
        isRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { engine.stop() }
    }
}

/// Real-time sine generator with a short fade (runs on the audio render thread: no allocations).
private final class ToneGenerator: @unchecked Sendable {
    private var phase = 0.0
    private var step = 0.0
    private var amplitude: Float = 0
    private var target: Float = 0
    private var ramp: Float = 0.0001

    func configure(sampleRate: Double, frequency: Double, level: Float) {
        phase = 0
        step = 2 * Double.pi * frequency / sampleRate
        amplitude = 0
        target = level
        ramp = level / Float(sampleRate * 0.08)      // 80 ms fade
    }

    func fadeOut() { target = 0 }

    func render(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for i in 0..<frames {
            if amplitude < target { amplitude = min(target, amplitude + ramp) }
            else if amplitude > target { amplitude = max(target, amplitude - ramp) }
            first[i] = amplitude * Float(sin(phase))
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        for buffer in buffers.dropFirst() {
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                data.update(from: first, count: frames)
            }
        }
    }
}
