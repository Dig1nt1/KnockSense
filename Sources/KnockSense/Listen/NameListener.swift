import AVFoundation
import Foundation
import KnockCore
import Speech

/// Listens for the user's name with Apple's speech recogniser, **on the Mac only** (offline
/// recognition is required; audio is never sent anywhere). Recognition tasks are limited to about a
/// minute, so a fresh one is started regularly.
final class NameListener: @unchecked Sendable {
    var onName: (@Sendable (String) -> Void)?
    /// A problem to show the user, or nil when everything is fine.
    var onProblem: (@Sendable (String?) -> Void)?

    private let queue = DispatchQueue(label: "app.knocksense.names")
    // Everything below is only touched on `queue`.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var names: [String] = []
    private var generation = 0
    private var reported = 0
    private var taskStarted = Date()
    private var lastAlert = Date.distantPast
    private var active = false

    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var denied: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .denied || status == .restricted
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    func start(names: [String], localeID: String) {
        queue.async {
            self.stopTask()
            let locale = localeID.isEmpty ? Locale.current : Locale(identifier: localeID)
            let languageName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                self.onProblem?("Speech recognition isn't available for \(languageName). Pick another language.")
                return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                self.onProblem?("Offline speech recognition for \(languageName) isn't available on this Mac. Pick English (US), or add the language under System Settings ▸ Keyboard ▸ Dictation.")
                return
            }
            self.recognizer = recognizer
            self.names = names
            self.active = true
            self.onProblem?(nil)
            self.beginTask()
        }
    }

    func stop() {
        queue.async { self.stopTask() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            guard self.active, let request = self.request else { return }
            request.append(buffer)
            if Date().timeIntervalSince(self.taskStarted) > 45 { self.beginTask() }
        }
    }

    private func stopTask() {
        active = false
        generation += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func beginTask() {
        guard active, let recognizer else { return }
        generation += 1
        let current = generation
        request?.endAudio()
        task?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true      // never send audio off the Mac
        request.contextualStrings = names               // helps with unusual names
        request.addsPunctuation = false
        self.request = request
        reported = 0
        taskStarted = Date()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            self.queue.async {
                guard current == self.generation, self.active else { return }
                if let transcript {
                    let found = NameMatcher.matches(in: transcript, names: self.names)
                    if found.count > self.reported {
                        self.reported = found.count
                        if Date().timeIntervalSince(self.lastAlert) > 6, let name = found.last {
                            self.lastAlert = Date()
                            self.onName?(name)
                        }
                    }
                }
                if isFinal {
                    self.beginTask()
                } else if failed {
                    // e.g. a long silence ended the task: start a new one shortly.
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        if current == self.generation, self.active { self.beginTask() }
                    }
                }
            }
        }
    }
}
