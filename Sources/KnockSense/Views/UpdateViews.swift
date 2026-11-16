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

/// Compact "Updates" button for the menu footer (shows a spinner while busy).
struct UpdateFooterButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button {
            Task { await updater.checkAndInstall() }
        } label: {
            HStack(spacing: 5) {
                if updater.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isAvailable ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                }
                Text(isAvailable ? "Install Update" : "Updates")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary)
        .disabled(updater.isBusy)
        .help("Check for a newer version and install it")
    }

    private var isAvailable: Bool {
        if case .available = updater.status { return true }
        return false
    }
}

/// One line about the update status, only when there's something to say.
struct UpdateStatusNote: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String? {
        switch updater.status {
        case .idle: return nil
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date (\(updater.versionText))."
        case .available(let info): return "Build \(info.build) is ready to install."
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing — KnockSense will restart…"
        case .failed(let reason): return "Couldn't update: \(reason)"
        }
    }

    private var color: Color {
        switch updater.status {
        case .failed: return .red
        case .available: return .accentColor
        default: return .secondary
        }
    }
}
