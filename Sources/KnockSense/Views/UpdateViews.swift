import SwiftUI
import KnockCore

/// "Check for Updates" button plus a one-line status, used in the menu and in Settings.
struct UpdateControls: View {
    @ObservedObject var updater: Updater
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await updater.checkAndInstall() }
                } label: {
                    Label(buttonTitle, systemImage: "arrow.down.circle")
                }
                .disabled(updater.isBusy)

                if updater.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttonTitle: String {
        if case .available(let info) = updater.status { return "Install Update (build \(info.build))" }
        return compact ? "Check for Updates" : "Check for Updates Now"
    }

    private var message: String? {
        switch updater.status {
        case .idle: return nil
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date — version \(updater.versionText)."
        case .available(let info): return "A new version is ready (build \(info.build)). Click to install; KnockSense restarts by itself."
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing — KnockSense will restart in a moment…"
        case .failed(let reason): return "Couldn't update: \(reason)"
        }
    }

    private var messageColor: Color {
        switch updater.status {
        case .available: return .accentColor
        case .failed: return .red
        case .upToDate: return .green
        default: return .secondary
        }
    }
}
