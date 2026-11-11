import AppKit
import SwiftUI

@main
struct KnockSenseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        if state.guardian.isAlarming { return "exclamationmark.shield.fill" }
        if state.guardian.isActive { return "lock.shield.fill" }
        if state.flash { return "hand.tap.fill" }
        return state.listening && state.config.enabled ? "hand.tap" : "hand.raised.slash"
    }
}

/// Menu-bar apps have no Dock icon, and the icon can be hidden behind the MacBook notch. So when the
/// user opens KnockSense again from Finder / Launchpad / Spotlight while it's running, show the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let state = AppState.current {
            SettingsWindowController.shared.show(state: state)
        }
        return true
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
