import AVFoundation
import KnockCore

enum AudioPipelineError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input is available."
        }
    }
}

/// Captures microphone audio with AVAudioEngine and runs the knock detector on a background queue.
/// Audio is analysed in memory only — nothing is recorded or sent anywhere.
final class AudioPipeline: @unchecked Sendable {
    var onKnock: (@Sendable (KnockEvent) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called (on the main queue) after the input device changed and the engine restarted; carries an error message if it failed.
    var onRestart: (@Sendable (String?) -> Void)?

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "app.knocksense.audio", qos: .userInitiated)
    private var detector: KnockDetector?      // only touched on `queue`
    private var params: DetectorParams        // only touched on `queue` after init
    private var lastLevelTime = 0.0
    private var configObserver: NSObjectProtocol?

    private(set) var isRunning = false
    private(set) var inputDescription = "—"
    /// Listen to the built-in mic even when AirPods/a headset are the system default input.
    var preferBuiltInMic = true

    init(params: DetectorParams) {
        self.params = params
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode

        var usingBuiltIn = false
        if preferBuiltInMic, let device = AudioDevices.builtInMicrophone(), let unit = input.audioUnit {
            usingBuiltIn = AudioDevices.setInputDevice(device, on: unit)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw AudioPipelineError.noInputDevice }

        // format: nil lets the engine use the device's real format; the detector is (re)built from
        // the first buffer's format, so a device switch can never cause a format mismatch.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            let sampleRate = buffer.format.sampleRate
            var copy: [[Float]] = []
            copy.reserveCapacity(count)
            for c in 0..<count {
                copy.append(Array(UnsafeBufferPointer(start: data[c], count: frames)))
            }
            self.queue.async { self.process(copy, sampleRate: sampleRate) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        let name = usingBuiltIn ? "Built-in microphone" : (AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone")
        inputDescription = "\(name) · \(format.channelCount) ch · \(Int(format.sampleRate)) Hz"

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func stop() {
        guard isRunning else { return }
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        queue.async { self.detector = nil }
    }

    func updateParams(_ newParams: DetectorParams) {
        queue.async {
            self.params = newParams
            self.detector?.params = newParams
        }
    }

    /// Input device changed (headset plugged in, default mic switched…): rebuild the engine.
    private func handleConfigurationChange() {
        stop()
        engine = AVAudioEngine()
        var message: String?
        do { try start() } catch { message = error.localizedDescription }
        onRestart?(message)
    }

    private func process(_ channels: [[Float]], sampleRate: Double) {
        guard !channels.isEmpty, sampleRate > 0 else { return }
        if detector == nil || detector?.sampleRate != sampleRate || detector?.channelCount != channels.count {
            detector = KnockDetector(sampleRate: sampleRate, channelCount: channels.count, params: params)
        }
        guard let detector else { return }
        let events = detector.process(channels)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelTime > 0.066 {
            lastLevelTime = now
            onLevel?(detector.takeLevel())
        }
        for event in events { onKnock?(event) }
    }
}
