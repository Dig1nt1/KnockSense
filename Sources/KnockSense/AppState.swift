import AppKit
import ApplicationServices
import AVFoundation
import Combine
import KnockCore

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

struct TrainingSession: Equatable {
    /// The area being trained, or nil for "Teach my knock".
    let zoneID: UUID?
    let total: Int
    var remaining: Int
}

/// Mic level lives in its own object so the 15 Hz meter updates don't re-render every view.
@MainActor
final class LevelModel: ObservableObject {
    @Published var level: Float = 0
}

enum MicStatus {
    case unknown, authorized, denied
}

/// Persists the configuration as JSON in ~/Library/Application Support/KnockSense/config.json.
struct ConfigStore {
    let url: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KnockSense", isDirectory: true)
        .appendingPathComponent("config.json")

    func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            NSLog("KnockSense: could not save config: \(error)")
        }
    }
}

/// Central app model: wires microphone → detector → zone classifier → pattern grouper → actions.
@MainActor
final class AppState: ObservableObject {
    static let trainingKnocks = 6
    static let knockTrainingKnocks = 8
    static let maxRejectedSounds = 100
    /// The running app's state, for AppKit callbacks that live outside SwiftUI.
    static weak var current: AppState?

    @Published var config: AppConfig {
        didSet { configDidChange(from: oldValue) }
    }
    @Published var training: TrainingSession?
    @Published var testMode = false

    @Published private(set) var flash = false
    @Published private(set) var lastKnock = "No knocks yet"
    @Published private(set) var micStatus: MicStatus = .unknown
    @Published private(set) var listening = false
    @Published private(set) var engineError: String?
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var lastFeatureDimension: Int?
    @Published private(set) var inputDescription = "—"
    @Published private(set) var zoneAccuracy: Double?
    let levelModel = LevelModel()
    let updater = Updater()
    let guardian = LaptopGuard()
    private var guardianLink: AnyCancellable?
    @Published private(set) var motionState: MotionSensor.State = .stopped
    @Published private(set) var helperInstalled = MotionHelperInstaller.isInstalled
    @Published private(set) var helperMessage: String?
    /// Set when the microphone is "on" but delivering nothing (usually a stale macOS permission).
    @Published private(set) var micProblem: String?
    /// Accessibility permission (needed to press keyboard shortcuts and media keys).
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    /// The last app other than KnockSense that was in front (KnockSense's own windows don't count).
    private var lastOtherApp: NSRunningApplication?
    private var appObserver: NSObjectProtocol?

    private let store = ConfigStore()
    private let audio: AudioPipeline
    private let motion: MotionSensor
    private let grouper: PatternGrouper
    private var pollTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var suppressUntil: TimeInterval = 0
    private var watchdogTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var lastRecovery: TimeInterval = 0
    /// Knocks of the pattern currently being collected (parallel to the grouper).
    private var pendingKnocks: [SoundSample] = []
    /// The sounds behind the most recent action, for "That wasn't me".
    @Published private(set) var lastFiredKnocks: [SoundSample] = []
    @Published private(set) var lastFiredAt: Date?

    init() {
        let loaded = store.load()
        let initial = loaded ?? AppConfig.defaults
        config = initial
        audio = AudioPipeline(params: .forSensitivity(initial.sensitivity))
        audio.preferBuiltInMic = initial.useBuiltInMic
        motion = MotionSensor(params: .forSensitivity(initial.sensitivity))
        grouper = PatternGrouper(gap: initial.knockGap, maxCount: RuleMatcher.maxKnockCount(in: initial.rules))
        zoneAccuracy = ZoneClassifier.selfTestAccuracy(zones: initial.zones)

        audio.onKnock = { [weak self] event in
            // Runs on the audio queue: do the heavier feature extraction here, then hop to the main actor.
            let features = FeatureExtractor.extract(event)
            let peak = event.peak
            guard let state = self else { return }
            Task { @MainActor in state.handleKnock(peak: peak, features: features) }
        }
        audio.onLevel = { [weak self] value in
            guard let state = self else { return }
            Task { @MainActor in state.levelModel.level = value }
        }
        audio.onRestart = { [weak self] error in
            guard let state = self else { return }
            Task { @MainActor in state.audioRestarted(error: error) }
        }

        motion.onTap = { [weak self] tap in
            guard let state = self else { return }
            Task { @MainActor in
                // The sensor may also be running just for Laptop Guard while the microphone is in use.
                guard state.config.detectionSource == .motion else { return }
                state.handleKnock(peak: Float(tap.peak), features: tap.features)
            }
        }
        motion.onMovement = { [weak self] description in
            guard let state = self else { return }
            Task { @MainActor in state.guardian.motionDetected(description) }
        }

        guardian.settings = { [weak self] in self?.config.guardSettings ?? GuardSettings() }
        guardian.log = { [weak self] message in self?.appendLog(message) }
        guardian.setMotionWatch = { [weak self] on in self?.setGuardMotionWatch(on) }
        // Let views watching AppState (menu bar icon, menu) update when the guard changes.
        guardianLink = guardian.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        motion.onLevel = { [weak self] value in
            guard let state = self else { return }
            Task { @MainActor in state.levelModel.level = value }
        }
        motion.onState = { [weak self] newState in
            guard let state = self else { return }
            Task { @MainActor in state.motionStateChanged(newState) }
        }

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.poll()
            }
        }

        updater.startAutomaticChecks { [weak self] in self?.config.autoCheckUpdates ?? false }

        // Give the audio system a moment after launch (starting instantly can fail at login),
        // then keep an eye on the microphone.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.config.enabled else { return }
            self.startListening()
        }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.checkMicrophoneHealth()
                self?.refreshAccessibility()
            }
        }

        // Remember the last "real" app in front, so knocking while KnockSense's own window or menu was
        // the last thing clicked still targets the app you were using.
        let ownID = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != ownID { lastOtherApp = front }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != ownID, let state = self else { return }
            Task { @MainActor in state.lastOtherApp = app }
        }
        if loaded == nil { store.save(initial) }
        AppState.current = self
        // Show the window only on the very first launch. Afterwards KnockSense starts quietly in the
        // menu bar; opening it again while it runs (Finder/Spotlight) brings the window up.
        if loaded == nil {
            Task { @MainActor in SettingsWindowController.shared.show(state: self) }
        }
    }

    // MARK: - Listening

    func startListening() {
        if config.detectionSource == .motion {
            engineError = nil
            inputDescription = "MacBook motion sensor"
            motion.start()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatus = .authorized
            startEngine()
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                self.micStatus = granted ? .authorized : .denied
                if granted && self.config.enabled { self.startEngine() }
            }
        default:
            micStatus = .denied
            listening = false
        }
    }

    func stopListening() {
        audio.stop()
        motion.stop()
        listening = false
        levelModel.level = 0
        grouper.reset()
        pendingKnocks = []
    }

    // MARK: - Microphone watchdog

    private func checkMicrophoneHealth() {
        guard config.enabled, config.detectionSource == .microphone, micStatus == .authorized else {
            micProblem = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecovery > 5 else { return }      // give each restart time to settle

        if !listening {
            // Starting failed earlier (e.g. right at launch): keep retrying quietly.
            lastRecovery = now
            startEngine()
            return
        }
        let health = audio.health()
        let noAudio = health.secondsSinceAudio > 3
        let silent = health.secondsSilent > 4
        guard noAudio || silent else {
            if health.secondsSilent == 0 { recoveryAttempts = 0; micProblem = nil }
            return
        }
        if recoveryAttempts < 2 {
            recoveryAttempts += 1
            lastRecovery = now
            appendLog(noAudio ? "Microphone stopped sending sound — restarting it" : "Microphone is silent — restarting it")
            restartMicrophone(log: false)
        } else {
            micProblem = "KnockSense isn't getting any sound from the microphone. macOS is probably blocking it for this version of the app."
        }
    }

    /// Restarts audio capture with a fresh engine.
    func restartMicrophone(log: Bool = true) {
        do {
            try audio.restart()
            listening = true
            engineError = nil
            inputDescription = audio.inputDescription
            if log { appendLog("Microphone restarted") }
        } catch {
            listening = false
            engineError = error.localizedDescription
        }
    }

    /// Resets KnockSense's microphone permission and asks again. Fixes a permission macOS
    /// remembered for an older build (each update is signed differently).
    func fixMicrophoneAccess() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.knocksense.app"
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Microphone", bundleID]
        try? reset.run()
        reset.waitUntilExit()
        micProblem = nil
        recoveryAttempts = 0
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            self.micStatus = granted ? .authorized : .denied
            if granted {
                self.restartMicrophone(log: false)
                self.appendLog("Microphone access renewed")
            } else {
                self.appendLog("Microphone access was not allowed")
            }
        }
    }

    private func motionStateChanged(_ newState: MotionSensor.State) {
        motionState = newState
        helperInstalled = MotionHelperInstaller.isInstalled
        guard config.detectionSource == .motion else { return }
        listening = newState == .streaming
        if newState == .streaming { appendLog("Motion sensor connected") }
    }

    /// Laptop Guard uses the motion sensor even when knocks come from the microphone.
    private func setGuardMotionWatch(_ on: Bool) {
        motion.setMovementWatch(on)
        guard config.detectionSource != .motion else { return }
        if on {
            if helperInstalled || MotionHelperInstaller.isInstalled { motion.start() }
        } else {
            motion.stop()
        }
    }

    // MARK: - Motion helper

    func installMotionHelper() {
        let error = MotionHelperInstaller.install()
        helperInstalled = MotionHelperInstaller.isInstalled
        helperMessage = error ?? "Helper installed. Connecting to the motion sensor…"
        if error == nil, config.enabled, config.detectionSource == .motion {
            motion.stop()
            motion.start()
        }
    }

    func uninstallMotionHelper() {
        let error = MotionHelperInstaller.uninstall()
        helperInstalled = MotionHelperInstaller.isInstalled
        helperMessage = error ?? "Helper removed."
    }

    private func startEngine() {
        do {
            try audio.start()
            listening = true
            engineError = nil
            inputDescription = audio.inputDescription
        } catch {
            listening = false
            engineError = error.localizedDescription
        }
    }

    private func audioRestarted(error: String?) {
        listening = audio.isRunning
        engineError = error
        inputDescription = audio.inputDescription
        appendLog(error == nil ? "Microphone changed: \(audio.inputDescription)" : "Microphone error: \(error!)")
    }

    // MARK: - Knock handling

    private func handleKnock(peak: Float, features: [Double]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard config.enabled, now >= suppressUntil, !features.isEmpty else { return }
        guard !guardian.isActive else { return }      // no knock actions while Laptop Guard is armed
        if config.ignoreWhileTyping && training == nil && InputActivity.secondsSinceLastInput() < 0.35 {
            return
        }
        lastFeatureDimension = features.count
        pulse()

        if var session = training {
            let name: String
            if let zoneID = session.zoneID {
                guard let index = config.zones.firstIndex(where: { $0.id == zoneID }) else {
                    training = nil
                    return
                }
                // Samples from a different microphone setup can't be compared; drop them.
                if config.zones[index].samples.contains(where: { $0.count != features.count }) {
                    config.zones[index].samples = []
                    config.zones[index].peaks = []
                }
                // Keep peaks aligned with samples (older configs may have samples without peaks).
                while config.zones[index].peaks.count < config.zones[index].samples.count { config.zones[index].peaks.append(0) }
                config.zones[index].samples.append(features)
                config.zones[index].peaks.append(Double(peak))
                name = config.zones[index].name
            } else {
                if config.knockSamples.contains(where: { $0.count != features.count }) {
                    config.knockSamples = []
                    config.knockPeaks = []
                }
                config.knockSamples.append(features)
                config.knockPeaks.append(Double(peak))
                name = "your knock"
            }
            session.remaining -= 1
            lastKnock = "Training \(name): \(session.total - session.remaining)/\(session.total)"
            if session.remaining <= 0 {
                training = nil
                appendLog("Finished training “\(name)”")
                playFeedback()
            } else {
                training = session
            }
            return
        }

        let sound = SoundSample(features: features, peak: peak)
        if config.verifyKnocks {
            let verdict = KnockVerifier.verify(sound, knocks: config.trainedKnocks, rejected: config.rejectedSounds)
            if let reason = Self.rejectionReason(verdict) {
                lastKnock = "Ignored a sound — \(reason)"
                if testMode { appendLog("Test: ignored a sound — \(reason)") }
                return
            }
        }

        let result = ZoneClassifier.classify(features, zones: config.zones)
        let zoneName = result.flatMap { r in config.zones.first { $0.id == r.zoneID }?.name }
        let strength = String(format: "%.2f", peak)
        if let zoneName, let result {
            lastKnock = "Knock on \(zoneName) (\(Int(result.confidence * 100))% sure) · strength \(strength)"
        } else {
            lastKnock = "Knock · strength \(strength)"
        }

        if testMode {
            appendLog("Test: \(zoneName.map { "knock on \($0)" } ?? "knock (no areas trained)")")
            return
        }
        pendingKnocks.append(sound)
        for pattern in grouper.add(at: now, zone: result?.zoneID) { fire(pattern) }
    }

    private func poll() {
        if let pattern = grouper.poll(now: ProcessInfo.processInfo.systemUptime) { fire(pattern) }
    }

    private static func rejectionReason(_ verdict: KnockVerifier.Verdict) -> String? {
        switch verdict {
        case .accepted, .notTrained: return nil
        case .notLikeYourKnock: return "it didn't sound like your knock"
        case .markedAsNotAKnock: return "it sounded like something you marked “That wasn't me”"
        case .tooQuiet: return "it was much quieter than your knocks"
        }
    }

    private func fire(_ pattern: KnockPattern) {
        // The grouper emits patterns oldest first; take this pattern's knocks off the front.
        let count = min(pattern.count, pendingKnocks.count)
        let knocks = Array(pendingKnocks.prefix(count))
        pendingKnocks.removeFirst(count)
        if config.requireConsistentPatterns && !PatternConsistency.isConsistent(knocks) {
            appendLog("Ignored \(pattern.count) sounds — they didn't sound like one knock pattern (e.g. a door)")
            return
        }

        let zoneName = pattern.zoneID.flatMap { id in config.zones.first { $0.id == id }?.name }
        let target = targetApp()
        let targetID = target?.bundleIdentifier
        let rules = RuleMatcher.match(pattern, rules: config.rules, frontmostApp: targetID)
        let description = "\(pattern.count) knock\(pattern.count == 1 ? "" : "s")"
            + (zoneName.map { " on \($0)" } ?? "") + (target?.localizedName.map { " in \($0)" } ?? "")
        guard !rules.isEmpty else {
            appendLog("\(description) — no action set")
            return
        }
        for rule in rules {
            perform(rule, in: target)
            appendLog("\(description) → \(rule.name)")
        }
        lastFiredKnocks = knocks
        lastFiredAt = Date()
        playFeedback()
    }

    // MARK: - Per-app targeting

    /// The app a knock is meant for: the app in front, or, if KnockSense itself is in front (its
    /// settings window or menu), the app that was in front before it.
    func targetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier || front == nil {
            return lastOtherApp
        }
        return front
    }

    /// Runs a rule's action in `app`, bringing that app to the front first if KnockSense was in front
    /// (so keyboard shortcuts land in the right app, not in KnockSense's window).
    private func perform(_ rule: Rule, in app: NSRunningApplication?) {
        if ActionRunner.needsAccessibility(rule.action) && !AXIsProcessTrusted() {
            appendLog("“\(rule.name)” needs Accessibility permission — see the warning in Settings ▸ Actions")
            accessibilityTrusted = false
        }
        let frontIsSelf = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        let id = app?.bundleIdentifier
        if frontIsSelf, let app, rule.action.kind == .keystroke {
            app.activate(options: [])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                ActionRunner.run(rule.action, frontApp: id)
            }
        } else {
            ActionRunner.run(rule.action, frontApp: id)
        }
    }

    /// "Test" button: for an app-specific action, switch to that app first and run it there.
    func test(_ rule: Rule) {
        guard let appID = rule.appBundleID else {
            perform(rule, in: targetApp())
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first else {
            appendLog("Open \(rule.appName ?? appID) first, then test “\(rule.name)”")
            NSSound.beep()
            return
        }
        app.activate(options: [])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            ActionRunner.run(rule.action, frontApp: appID)
        }
    }

    private func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    /// True when some enabled action can't work until Accessibility is allowed.
    var accessibilityNeeded: Bool {
        !accessibilityTrusted && config.rules.contains { $0.enabled && ActionRunner.needsAccessibility($0.action) }
    }

    private func playFeedback() {
        guard config.playSound else { return }
        NSSound(named: "Tink")?.play()
        // Don't let our own feedback sound be heard as a knock.
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.35
    }

    private func pulse() {
        flash = true
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = false
        }
    }

    func appendLog(_ text: String) {
        log.insert(LogEntry(text: text), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    // MARK: - Config changes

    private func configDidChange(from old: AppConfig) {
        if config.sensitivity != old.sensitivity {
            audio.updateParams(.forSensitivity(config.sensitivity))
            motion.updateParams(.forSensitivity(config.sensitivity))
        }
        grouper.gap = config.knockGap
        grouper.maxCount = RuleMatcher.maxKnockCount(in: config.rules)
        if config.zones != old.zones {
            zoneAccuracy = ZoneClassifier.selfTestAccuracy(zones: config.zones)
        }
        if config.enabled != old.enabled {
            if config.enabled { startListening() } else { stopListening() }
        } else if config.detectionSource != old.detectionSource {
            appendLog(config.detectionSource == .motion ? "Switched to the motion sensor" : "Switched to the microphone")
            if config.enabled {
                stopListening()
                startListening()
            }
        } else if config.useBuiltInMic != old.useBuiltInMic {
            audio.preferBuiltInMic = config.useBuiltInMic
            if listening {
                stopListening()
                startListening()
            }
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = config
        let store = self.store
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            store.save(snapshot)
        }
    }

    // MARK: - Rules

    func upsert(_ rule: Rule) {
        if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
            config.rules[index] = rule
        } else {
            config.rules.append(rule)
        }
    }

    func deleteRule(_ id: UUID) {
        config.rules.removeAll { $0.id == id }
    }

    // MARK: - Zones

    func addZone(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        config.zones.append(Zone(name: trimmed.isEmpty ? "Area \(config.zones.count + 1)" : trimmed))
    }

    func deleteZone(_ id: UUID) {
        if training?.zoneID == id { training = nil }
        config.zones.removeAll { $0.id == id }
        // Rules pointing at the deleted area are disabled rather than silently becoming "anywhere".
        for index in config.rules.indices where config.rules[index].zoneID == id {
            config.rules[index].zoneID = nil
            config.rules[index].enabled = false
        }
    }

    func clearSamples(_ id: UUID) {
        if let index = config.zones.firstIndex(where: { $0.id == id }) {
            config.zones[index].samples = []
            config.zones[index].peaks = []
        }
    }

    func startTraining(_ id: UUID) {
        if !config.enabled { config.enabled = true }
        testMode = false
        training = TrainingSession(zoneID: id, total: Self.trainingKnocks, remaining: Self.trainingKnocks)
        grouper.reset()
        pendingKnocks = []
    }

    // MARK: - False-trigger protection

    /// "Teach my knock": the next knocks are recorded as the user's knock signature.
    func startKnockTraining() {
        if !config.enabled { config.enabled = true }
        testMode = false
        training = TrainingSession(zoneID: nil, total: Self.knockTrainingKnocks, remaining: Self.knockTrainingKnocks)
        grouper.reset()
        pendingKnocks = []
    }

    func clearKnockTraining() {
        config.knockSamples = []
        config.knockPeaks = []
    }

    /// Number of trained knocks the verifier can use with the current microphone.
    var trainedKnockCount: Int {
        let all = config.trainedKnocks
        guard let dim = lastFeatureDimension else { return all.count }
        return all.filter { $0.features.count == dim }.count
    }

    /// Offer "That wasn't me" for a minute after an action ran.
    var canMarkLastAsNotMe: Bool {
        guard let at = lastFiredAt, !lastFiredKnocks.isEmpty else { return false }
        return Date().timeIntervalSince(at) < 60
    }

    func markLastAsNotMe() {
        guard !lastFiredKnocks.isEmpty else { return }
        config.rejectedSounds.append(contentsOf: lastFiredKnocks.map(\.features))
        if config.rejectedSounds.count > Self.maxRejectedSounds {
            config.rejectedSounds.removeFirst(config.rejectedSounds.count - Self.maxRejectedSounds)
        }
        lastFiredKnocks = []
        lastFiredAt = nil
        if trainedKnockCount < KnockVerifier.minimumSamples {
            appendLog("Noted. Use “Teach my knock” in Settings so KnockSense can tell your knocks from sounds like that.")
        } else {
            appendLog("Got it — KnockSense will ignore sounds like that from now on.")
        }
    }

    func forgetRejectedSounds() {
        config.rejectedSounds = []
    }

    func zoneName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return config.zones.first { $0.id == id }?.name
    }

    /// Samples recorded with the current microphone layout (others are ignored by the classifier).
    func usableSampleCount(_ zone: Zone) -> Int {
        guard let dim = lastFeatureDimension else { return zone.samples.count }
        return zone.samples.filter { $0.count == dim }.count
    }
}
