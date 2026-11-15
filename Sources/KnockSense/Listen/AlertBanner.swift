import AppKit
import SwiftUI

/// A small banner that slides in at the top of the screen for a few seconds ("Someone said …").
@MainActor
final class AlertBanner {
    static let shared = AlertBanner()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(title: String, subtitle: String) {
        let size = NSSize(width: 400, height: 78)
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main else { return }
        panel.contentViewController = NSHostingController(rootView: BannerView(title: title, subtitle: subtitle))
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                                completionHandler: { panel.orderOut(nil) })
        }
    }
}

private struct BannerView: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Text("👋").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 400, height: 78)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}
