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
}
