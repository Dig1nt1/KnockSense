import AppKit
import SwiftUI

@main
struct KnockSenseApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if state.flash { return "hand.tap.fill" }
        return state.listening && state.config.enabled ? "hand.tap" : "hand.raised.slash"
    }
}

/// Hosts the SwiftUI settings view in a regular window (menu-bar apps have no main window).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(state))
            let window = NSWindow(contentViewController: host)
            window.title = "KnockSense"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 540))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
