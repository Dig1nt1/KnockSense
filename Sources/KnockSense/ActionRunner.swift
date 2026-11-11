import AppKit
import ApplicationServices
import KnockCore

/// Executes the action attached to a rule.
enum ActionRunner {
    static func run(_ action: KnockAction) {
        let arg = action.argument.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.kind {
        case .builtin:
            if let builtin = BuiltinAction(rawValue: arg) { run(builtin) }

        case .openApp:
            if arg.contains("/") {
                let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                launch("/usr/bin/open", ["-a", arg])
            }

        case .openURL:
            if arg.hasPrefix("/") || arg.hasPrefix("~") {
                NSWorkspace.shared.open(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
            } else if let url = URL(string: arg), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: "https://" + arg) {
                NSWorkspace.shared.open(url)
            }

        case .shell:
            // Login shell so the user's PATH (Homebrew etc.) is available.
            launch("/bin/zsh", ["-lc", arg])

        case .appleScript:
            launch("/usr/bin/osascript", ["-e", arg])

        case .shortcut:
            launch("/usr/bin/shortcuts", ["run", arg])
        }
    }

    static func run(_ action: BuiltinAction) {
        switch action {
        case .playPause: postMediaKey(16)        // NX_KEYTYPE_PLAY
        case .nextTrack: postMediaKey(17)        // NX_KEYTYPE_NEXT
        case .previousTrack: postMediaKey(18)    // NX_KEYTYPE_PREVIOUS
        case .volumeUp:
            osascript("set volume output volume ((output volume of (get volume settings)) + 10)")
        case .volumeDown:
            osascript("set volume output volume ((output volume of (get volume settings)) - 10)")
        case .toggleMute:
            osascript("set volume output muted (not (output muted of (get volume settings)))")
        case .lockScreen:
            osascript(#"tell application "System Events" to keystroke "q" using {control down, command down}"#)
        case .sleepDisplay:
            launch("/usr/bin/pmset", ["displaysleepnow"])
        case .screenshot:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let file = desktop.appendingPathComponent("Knock Screenshot \(formatter.string(from: Date())).png")
            launch("/usr/sbin/screencapture", ["-x", file.path])
        case .missionControl:
            launch("/usr/bin/open", ["-a", "Mission Control"])
        case .notify:
            osascript(#"display notification "Knock detected!" with title "KnockSense""#)
        }
    }

    // MARK: - Helpers

    private static func osascript(_ script: String) {
        launch("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    private static func launch(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            NSLog("KnockSense: failed to launch \(path): \(error)")
            return false
        }
    }

    /// Simulates a hardware media key (play/pause, next…). Requires Accessibility permission.
    private static func postMediaKey(_ key: Int) {
        func post(keyDown: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((keyDown ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(keyDown: true)
        post(keyDown: false)
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security ▸ Accessibility.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum InputActivity {
    /// Seconds since the last key press or mouse/trackpad click. Needs no special permission.
    static func secondsSinceLastInput() -> Double {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .otherMouseDown]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
}
