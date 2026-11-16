import AppKit
import SwiftUI

/// Renders the menu and every settings page to PNGs (light and dark), then quits. Used by CI so the
/// design can be reviewed without a screen; it only captures KnockSense's own views.
@MainActor
enum UISnapshotter {
    static func run(state: AppState, folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await snap(MenuView().environmentObject(state), width: 320, height: nil,
                           to: folder.appendingPathComponent("menu-\(name).png"))
                for page in SettingsPage.allCases {
                    await snap(SettingsView(initialPage: page).environmentObject(state), width: 900, height: 640,
                               to: folder.appendingPathComponent("settings-\(page.rawValue)-\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func snap<V: View>(_ view: V, width: CGFloat, height: CGFloat?, to url: URL) async {
        let host = NSHostingView(rootView: view)
        let size = CGSize(width: width, height: height ?? max(200, host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)     // let SwiftUI lay out and draw
        if height == nil {
            let fitted = CGSize(width: width, height: max(200, host.fittingSize.height))
            window.setContentSize(fitted)
            host.frame = CGRect(origin: .zero, size: fitted)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        host.layoutSubtreeIfNeeded()
        host.display()
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Ask the window server for the window's pixels: cacheDisplay skips layer-backed content
        // (lists, materials, most SwiftUI text). An app may always capture its own windows.
        if let image = captureWindow(CGWindowID(window.windowNumber)) {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        } else if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    /// CGWindowListCreateImage, looked up at run time (newer SDKs hide it in favour of ScreenCaptureKit).
    private static func captureWindow(_ id: CGWindowID) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3.
        return capture(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}
