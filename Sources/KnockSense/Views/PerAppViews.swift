import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KnockCore

/// "In app" picker for a rule: any app, a running app, or any other installed app.
struct AppPicker: View {
    @Binding var bundleID: String?
    @Binding var appName: String?
    @State private var running: [AppChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("In app", selection: selection) {
                    Text("Any app").tag("")
                    if let id = bundleID, !running.contains(where: { $0.id == id }) {
                        Text(appName ?? id).tag(id)
                    }
                    if !running.isEmpty { Divider() }
                    ForEach(running) { app in
                        Text(app.name).tag(app.id)
                    }
                }
                Button("Other…", action: chooseOther)
                    .help("Pick an app from your Applications folder")
            }
            Text(bundleID == nil
                 ? "Runs whatever app is in front."
                 : "Only runs while \(appName ?? "this app") is the app in front, and wins over “any app” actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { running = AppChoice.runningApps() }
    }

    private var selection: Binding<String> {
        Binding(
            get: { bundleID ?? "" },
            set: { id in
                if id.isEmpty {
                    bundleID = nil
                    appName = nil
                } else {
                    bundleID = id
                    appName = running.first { $0.id == id }?.name ?? appName
                }
            }
        )
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        bundleID = id
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct AppChoice: Identifiable, Hashable {
    let id: String      // bundle identifier
    let name: String

    /// Apps with a Dock icon that are running right now (handy to pick from).
    static func runningApps() -> [AppChoice] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppChoice? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return AppChoice(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Click, then press a key combination to record it (stored as text like "cmd+shift+a").
struct ShortcutRecorder: View {
    @Binding var value: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if !value.isEmpty && !recording {
                Button { value = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
        }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if recording { return "Press keys…" }
        return KeyShortcut.parse(value)?.display ?? "Record Shortcut"
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc on its own cancels recording.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && flags.isDisjoint(with: [.command, .shift, .option, .control]) {
                stopRecording()
                return nil
            }
            var modifiers = Set<KeyShortcut.Modifier>()
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if let shortcut = KeyShortcut.from(keyCode: event.keyCode, modifiers: modifiers) {
                value = shortcut.string
            }
            stopRecording()
            return nil      // don't let the key reach the window (e.g. ⌘W)
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Ready-made per-app actions shown in the "Per-App Examples" menu.
struct AppActionExample: Identifiable {
    let id: String
    let title: String
    let rule: Rule

    static var all: [AppActionExample] {
        func make(_ title: String, _ name: String, _ appID: String, _ appName: String, _ action: KnockAction) -> AppActionExample {
            AppActionExample(id: appID + title, title: title,
                             rule: Rule(name: name, knockCount: 2, action: action, appBundleID: appID, appName: appName))
        }
        return [
            make("Spotify: double knock → next song", "Next song in Spotify", "com.spotify.client", "Spotify", .builtin(.nextTrack)),
            make("Music: double knock → next song", "Next song in Music", "com.apple.Music", "Music", .builtin(.nextTrack)),
            make("Zoom: double knock → mute / unmute (⇧⌘A)", "Mute in Zoom", "us.zoom.xos", "zoom.us",
                 KnockAction(kind: .keystroke, argument: "shift+cmd+a")),
            make("Microsoft Teams: double knock → mute / unmute (⇧⌘M)", "Mute in Teams", "com.microsoft.teams2", "Microsoft Teams",
                 KnockAction(kind: .keystroke, argument: "shift+cmd+m")),
            make("Safari: double knock → new tab (⌘T)", "New tab in Safari", "com.apple.Safari", "Safari",
                 KnockAction(kind: .keystroke, argument: "cmd+t")),
            make("Google Chrome: double knock → new tab (⌘T)", "New tab in Chrome", "com.google.Chrome", "Google Chrome",
                 KnockAction(kind: .keystroke, argument: "cmd+t")),
            make("Keynote: double knock → next slide (→)", "Next slide in Keynote", "com.apple.iWork.Keynote", "Keynote",
                 KnockAction(kind: .keystroke, argument: "right")),
        ]
    }
}
