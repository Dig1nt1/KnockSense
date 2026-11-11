import AppKit
import AVFoundation
import KnockCore
import ServiceManagement

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

struct TrainingSession: Equatable {
    let zoneID: UUID
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

    private let store = ConfigStore()
    private let audio: AudioPipeline
    private let grouper: PatternGrouper
    private var pollTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var suppressUntil: TimeInterval = 0

    init() {
        let loaded = store.load()
        let initial = loaded ?? AppConfig.defaults
        config = initial
        audio = AudioPipeline(params: .forSensitivity(initial.sensitivity))
        audio.preferBuiltInMic = initial.useBuiltInMic
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

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.poll()
            }
        }

        updater.startAutomaticChecks { [weak self] in self?.config.autoCheckUpdates ?? false }

        if initial.enabled { startListening() }
        if loaded == nil { store.save(initial) }
        AppState.current = self
        // Show the window whenever the user opens the app themselves, so it's obvious it started
        // (the menu-bar icon alone is easy to miss). Stay quiet when it starts automatically at login.
        if loaded == nil || SMAppService.mainApp.status != .enabled {
            Task { @MainActor in SettingsWindowController.shared.show(state: self) }
        }
    }

    // MARK: - Listening

    func startListening() {
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
        listening = false
        levelModel.level = 0
        grouper.reset()
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
        if config.ignoreWhileTyping && training == nil && InputActivity.secondsSinceLastInput() < 0.35 {
            return
        }
        lastFeatureDimension = features.count
        pulse()

        if var session = training {
            guard let index = config.zones.firstIndex(where: { $0.id == session.zoneID }) else {
                training = nil
                return
            }
            // Samples from a different microphone setup can't be compared; drop them.
            config.zones[index].samples.removeAll { $0.count != features.count }
            config.zones[index].samples.append(features)
            session.remaining -= 1
            let name = config.zones[index].name
            lastKnock = "Training “\(name)”: \(Self.trainingKnocks - session.remaining)/\(Self.trainingKnocks)"
            if session.remaining <= 0 {
                training = nil
                appendLog("Finished training “\(name)”")
                playFeedback()
            } else {
                training = session
            }
            return
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
        for pattern in grouper.add(at: now, zone: result?.zoneID) { fire(pattern) }
    }

    private func poll() {
        if let pattern = grouper.poll(now: ProcessInfo.processInfo.systemUptime) { fire(pattern) }
    }

    private func fire(_ pattern: KnockPattern) {
        let zoneName = pattern.zoneID.flatMap { id in config.zones.first { $0.id == id }?.name }
        let description = "\(pattern.count) knock\(pattern.count == 1 ? "" : "s")" + (zoneName.map { " on \($0)" } ?? "")
        let rules = RuleMatcher.match(pattern, rules: config.rules)
        guard !rules.isEmpty else {
            appendLog("\(description) — no action set")
            return
        }
        for rule in rules {
            ActionRunner.run(rule.action)
            appendLog("\(description) → \(rule.name)")
        }
        playFeedback()
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
        }
        grouper.gap = config.knockGap
        grouper.maxCount = RuleMatcher.maxKnockCount(in: config.rules)
        if config.zones != old.zones {
            zoneAccuracy = ZoneClassifier.selfTestAccuracy(zones: config.zones)
        }
        if config.enabled != old.enabled {
            if config.enabled { startListening() } else { stopListening() }
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
        }
    }

    func startTraining(_ id: UUID) {
        if !config.enabled { config.enabled = true }
        testMode = false
        training = TrainingSession(zoneID: id, remaining: Self.trainingKnocks)
        grouper.reset()
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
