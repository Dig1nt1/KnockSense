import AppKit
import CoreImage.CIFilterBuiltins
import KnockCore
import SwiftUI

// MARK: - Floating status panel (shown when armed without locking, and whenever it triggers)

@MainActor
final class GuardOverlay {
    static let shared = GuardOverlay()
    private var panel: NSPanel?

    func show(guardian: LaptopGuard) {
        if panel == nil {
            let host = NSHostingController(rootView: GuardOverlayView(guardian: guardian))
            let panel = NSPanel(contentViewController: host)
            panel.styleMask = [.titled, .fullSizeContentView]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.setContentSize(NSSize(width: 440, height: 260))
            self.panel = panel
        }
        panel?.center()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct GuardOverlayView: View {
    @ObservedObject var guardian: LaptopGuard

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: alarming ? "exclamationmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(alarming ? Color.white : Color.accentColor)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(alarming ? Color.white.opacity(0.9) : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guardian.requestDisarm()
            } label: {
                Label("Disarm with Touch ID", systemImage: "touchid")
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(alarming ? .white : .accentColor)
            .foregroundStyle(alarming ? Color.red : Color.white)
        }
        .padding(28)
        .frame(width: 440, height: 260)
        .background(alarming ? Color.red : Color.clear)
        .foregroundStyle(alarming ? Color.white : Color.primary)
    }

    private var alarming: Bool { guardian.isAlarming }

    private var title: String {
        switch guardian.phase {
        case .off: return "Laptop Guard is off"
        case .arming(let left): return "Arming in \(left)…"
        case .armed: return "Laptop Guard is armed"
        case .triggered(_, let left): return "Alarm in \(left)…"
        case .alarm: return "ALARM"
        }
    }

    private var subtitle: String {
        switch guardian.phase {
        case .off, .arming: return "Walk away — the guard turns on when the countdown ends."
        case .armed: return "This Mac is being watched. Moving it, touching it or unplugging it sets off the alarm."
        case .triggered(let reason, _): return "\(reason). Disarm now to stop the alarm."
        case .alarm(let reason): return "\(reason). The owner has been alerted."
        }
    }
}

// MARK: - Menu section

struct GuardMenuRow: View {
    @ObservedObject var guardian: LaptopGuard

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            switch guardian.phase {
            case .off:
                Button("Arm") { guardian.arm() }
            case .arming:
                Button("Cancel") { guardian.requestDisarm() }
            default:
                Button("Disarm…") { guardian.requestDisarm() }
            }
        }
    }

    private var icon: String {
        switch guardian.phase {
        case .off: return "shield"
        case .arming, .armed: return "lock.shield.fill"
        case .triggered, .alarm: return "exclamationmark.shield.fill"
        }
    }

    private var color: Color {
        switch guardian.phase {
        case .off: return .secondary
        case .arming, .armed: return .accentColor
        case .triggered, .alarm: return .red
        }
    }

    private var text: String {
        switch guardian.phase {
        case .off: return "Laptop Guard"
        case .arming(let left): return "Arming in \(left) s — walk away"
        case .armed: return "Laptop Guard armed"
        case .triggered(_, let left): return "Triggered! Alarm in \(left) s"
        case .alarm(let reason): return "ALARM: \(reason)"
        }
    }
}

// MARK: - Settings tab

struct GuardSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var guardian: LaptopGuard
    @State private var cameraAllowed = GuardCamera.authorized

    private var s: Binding<GuardSettings> { $state.config.guardSettings }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Leaving your Mac somewhere? Arm Laptop Guard. If anyone moves it, touches it, unplugs it or closes the lid, it takes a photo with the camera, sounds a loud alarm and alerts your phone. Unlock your Mac with Touch ID or your password to turn it off.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    GuardMenuRow(guardian: guardian)
                        .padding(.vertical, 4)
                }
            }

            Section("Watch for") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("The Mac being moved or picked up", isOn: s.watchMotion)
                    Text(motionNote).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Keyboard or trackpad being used", isOn: s.watchInput)
                Toggle("The charger being unplugged", isOn: s.watchPower)
                Toggle("The lid being closed", isOn: s.watchLid)
            }

            Section("When something happens") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Time to unlock before the alarm")
                        Spacer()
                        Text("\(Int(state.config.guardSettings.graceSeconds)) s").foregroundStyle(.secondary)
                    }
                    Slider(value: s.graceSeconds, in: 0...15, step: 1)
                }
                HStack {
                    Toggle("Take photos with the camera", isOn: s.takePhotos)
                    Spacer()
                    if state.config.guardSettings.takePhotos && !cameraAllowed {
                        Button("Allow Camera…") {
                            Task {
                                cameraAllowed = await GuardCamera.requestAccess()
                                if !cameraAllowed, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep the camera ready while armed", isOn: s.keepCameraReady)
                        .disabled(!state.config.guardSettings.takePhotos)
                    Text("Photos are instant and show the moment just before something happened. The green camera light stays on while the guard is armed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Sound a loud alarm", isOn: s.soundAlarm)
                Toggle("Full volume through the Mac's speakers", isOn: s.maxVolume)
                    .disabled(!state.config.guardSettings.soundAlarm)
                Toggle("Lock the screen when arming", isOn: s.lockScreen)
                HStack {
                    Button("Open Guard Photos") {
                        let folder = GuardCamera.photosFolder
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                    if let last = guardian.lastPhoto {
                        Text("Last: \(last.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Alerts on your phone") {
                Toggle("Send alerts to my phone", isOn: phoneAlertsBinding)
                if state.config.guardSettings.phoneAlerts {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = QRCode.image(for: "https://ntfy.sh/\(state.config.guardSettings.ntfyTopic)") {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 130, height: 130)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Install the free **ntfy** app on your iPhone (App Store).")
                            Text("2. In ntfy, tap **+** and subscribe to this topic:")
                            HStack {
                                Text(state.config.guardSettings.ntfyTopic)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(state.config.guardSettings.ntfyTopic, forType: .string)
                                } label: { Image(systemName: "doc.on.doc") }
                                .help("Copy")
                            }
                            Text("3. Allow notifications, then send a test:")
                            HStack {
                                Button("Send Test Alert") { guardian.sendTestAlert() }
                                if let result = guardian.testAlertResult {
                                    Text(result).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.callout)
                    }
                    Text("Alerts (with the photo) go through the public ntfy.sh service. The topic name works like a password: anyone who knows it can read your alerts, so don't share it. Make a new one if needed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("New Topic Name") { state.config.guardSettings.ntfyTopic = GuardSettings.randomTopic() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cameraAllowed = GuardCamera.authorized }
    }

    private var phoneAlertsBinding: Binding<Bool> {
        Binding(
            get: { state.config.guardSettings.phoneAlerts },
            set: { on in
                state.config.guardSettings.phoneAlerts = on
                if on && state.config.guardSettings.ntfyTopic.isEmpty {
                    state.config.guardSettings.ntfyTopic = GuardSettings.randomTopic()
                }
            }
        )
    }

    private var motionNote: String {
        if state.motionState == .streaming || state.helperInstalled {
            return "Uses the motion sensor helper."
        }
        return "Needs the motion sensor helper (Settings ▸ General ▸ Motion sensor). Without it, the other triggers still work."
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
