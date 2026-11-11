import ServiceManagement
import SwiftUI
import KnockCore

struct SettingsView: View {
    var body: some View {
        TabView {
            RulesView()
                .tabItem { Label("Actions", systemImage: "bolt.fill") }
            ZonesView()
                .tabItem { Label("Areas", systemImage: "square.grid.2x2") }
            GeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 460)
    }
}

// MARK: - General

struct GeneralView: View {
    @EnvironmentObject var state: AppState
    @State private var accessibilityGranted = Permissions.accessibilityGranted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Detection") {
                Toggle("Listen for knocks", isOn: $state.config.enabled)
                Picker("Sense knocks with", selection: $state.config.detectionSource) {
                    Text("Microphone").tag(DetectionSource.microphone)
                    Text("Motion sensor (beta)").tag(DetectionSource.motion)
                }
                if state.config.detectionSource == .motion {
                    MotionHelperRow()
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(sensitivityLabel(state.config.sensitivity)).foregroundStyle(.secondary)
                    }
                    Slider(value: $state.config.sensitivity, in: 0...1)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Max time between knocks")
                        Spacer()
                        Text(String(format: "%.2f s", state.config.knockGap)).foregroundStyle(.secondary)
                    }
                    Slider(value: $state.config.knockGap, in: 0.25...0.8)
                }
                Toggle("Ignore knocks while typing or clicking", isOn: $state.config.ignoreWhileTyping)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Always use the Mac's built-in microphone", isOn: $state.config.useBuiltInMic)
                    Text("Recommended. With AirPods or a headset connected, macOS switches to their microphone, which can't hear knocks on the Mac (and using it lowers AirPods sound quality).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Play a sound when an action runs", isOn: $state.config.playSound)
                HStack {
                    Text("Input")
                    Spacer()
                    Text(state.inputDescription).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    LevelMeter(model: state.levelModel).frame(height: 6)
                    Text(state.lastKnock).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Avoid false triggers") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Your knock", systemImage: "hand.tap")
                        Text(knockTrainingText)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let session = state.training, session.zoneID == nil {
                        ProgressView(value: Double(session.total - session.remaining), total: Double(session.total))
                            .frame(width: 70)
                        Text("Knock now… \(session.remaining) left").font(.caption.weight(.semibold))
                        Button("Cancel") { state.training = nil }
                    } else {
                        Button(state.config.knockSamples.isEmpty ? "Teach My Knock" : "Add More") {
                            state.startKnockTraining()
                        }
                        .disabled(state.training != nil)
                        if !state.config.knockSamples.isEmpty {
                            Button("Forget") { state.clearKnockTraining() }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Only react to sounds that match my knock", isOn: $state.config.verifyKnocks)
                    Text("Ignores doors, claps, footsteps and other sounds that don't sound like you knocking on the Mac, or are much quieter. Works once your knock is taught (or areas are trained).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Ignore knock patterns that don't sound alike", isOn: $state.config.requireConsistentPatterns)
                    Text("A door's latch click followed by the slam looks like a double knock, but the two sounds are different. Your knocks sound the same.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Sounds marked “That wasn't me”: \(state.config.rejectedSounds.count)")
                    Spacer()
                    Button("Forget Them") { state.forgetRejectedSounds() }
                        .disabled(state.config.rejectedSounds.isEmpty)
                }
            }

            Section("Permissions") {
                HStack {
                    Label("Microphone", systemImage: "mic.fill")
                    Spacer()
                    switch state.micStatus {
                    case .authorized: Text("Allowed").foregroundStyle(.green)
                    case .denied:
                        Button("Open Privacy Settings") { Permissions.openMicrophoneSettings() }
                    case .unknown: Text("Not requested yet").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Label("Accessibility", systemImage: "accessibility")
                        Text("Needed for media keys (play/pause, next track) and Lock screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if accessibilityGranted {
                        Text("Allowed").foregroundStyle(.green)
                    } else {
                        Button("Grant…") {
                            Permissions.requestAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                        Button("Check again") { accessibilityGranted = Permissions.accessibilityGranted }
                    }
                }
            }

            Section("Updates") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(state.updater.versionText).foregroundStyle(.secondary)
                }
                Toggle("Check for updates automatically", isOn: $state.config.autoCheckUpdates)
                UpdateControls(updater: state.updater)
                Text("Updates come from the KnockSense GitHub releases and are checked against a checksum before installing. After an update, macOS may ask for microphone access again, and you may need to switch KnockSense off and on under Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle("Launch KnockSense at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Recent activity") {
                if state.log.isEmpty {
                    Text("Nothing yet — try knocking twice on your Mac.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.log.prefix(15)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.date, style: .time).foregroundStyle(.tertiary).font(.caption)
                            Text(entry.text)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { accessibilityGranted = Permissions.accessibilityGranted }
    }

    private var knockTrainingText: String {
        let count = state.trainedKnockCount
        if count >= KnockVerifier.minimumSamples {
            return "Learned from \(count) of your knocks. Knock the way you normally will — teach more if real knocks get ignored."
        }
        return "Not taught yet. Click Teach My Knock, then knock \(AppState.knockTrainingKnocks) times on your Mac the way you normally will."
    }
}

/// Status and install controls for the motion-sensor helper.
struct MotionHelperRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Feels knocks through the MacBook's built-in motion sensor, so doors, voices and music can't set it off and the microphone stays off. Needs an Apple Silicon MacBook (M2 or newer) and your admin password once, to install a small background helper. Apple doesn't officially support reading this sensor, so a macOS update could break it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.callout)
                Spacer()
                if needsInstall {
                    Button(state.helperInstalled ? "Update Helper…" : "Install Helper…") { state.installMotionHelper() }
                        .buttonStyle(.borderedProminent)
                }
                if state.helperInstalled {
                    Button("Remove Helper…") { state.uninstallMotionHelper() }
                }
            }
            if let message = state.helperMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var needsInstall: Bool {
        switch state.motionState {
        case .helperNotRunning, .helperOutdated: return true
        default: return !state.helperInstalled
        }
    }

    private var statusText: String {
        switch state.motionState {
        case .streaming: return "Motion sensor active"
        case .stopped: return state.config.enabled ? "Starting…" : "Paused"
        case .connecting: return "Connecting…"
        case .helperNotRunning: return state.helperInstalled ? "Helper installed but not running" : "Helper not installed"
        case .noSensor: return "This Mac has no supported motion sensor — use the microphone instead"
        case .helperOutdated(let installed): return "Helper is out of date (v\(installed))"
        case .error(let message): return message
        }
    }

    private var statusColor: Color {
        switch state.motionState {
        case .streaming: return .green
        case .stopped, .connecting: return .yellow
        default: return .red
        }
    }
}

