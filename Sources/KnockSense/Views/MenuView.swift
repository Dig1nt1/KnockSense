import SwiftUI
import KnockCore

struct MenuView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            header
            notices
            liveCard
            Card { GuardMenuRow(guardian: state.guardian) }
            if !state.log.isEmpty { activityCard }
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("KnockSense").font(.system(size: 15, weight: .semibold))
                StatusLine()
            }
            Spacer(minLength: 8)
            Toggle("Listen for knocks", isOn: $state.config.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(state.config.enabled ? "Pause KnockSense" : "Turn KnockSense on")
        }
        .padding(.horizontal, 2)
    }

    // MARK: Notices (only when something needs attention)

    @ViewBuilder private var notices: some View {
        if state.config.detectionSource == .microphone && state.micStatus == .denied {
            NoticeRow(icon: "mic.slash.fill", tint: .red, text: "Microphone access is off",
                      buttonTitle: "Open Settings") { Permissions.openMicrophoneSettings() }
        } else if state.config.detectionSource == .microphone && state.micProblem != nil {
            NoticeRow(icon: "mic.badge.xmark", tint: .red, text: "The microphone isn't sending sound",
                      buttonTitle: "Fix") { state.fixMicrophoneAccess() }
        }
        if state.canMarkLastAsNotMe {
            NoticeRow(icon: "hand.raised.fill", tint: .orange, text: "Wasn't you? Ignore sounds like that",
                      buttonTitle: "Not Me") { state.markLastAsNotMe() }
        }
        if state.config.verifyKnocks && state.trainedKnockCount < KnockVerifier.minimumSamples && state.training == nil {
            NoticeRow(icon: "lightbulb.fill", tint: .yellow, text: "Teach KnockSense your knock to ignore doors and noise",
                      buttonTitle: "Teach") { state.startKnockTraining() }
        }
    }

    // MARK: Live meter + sensitivity

    private var liveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle("Live", icon: "waveform")
                    Spacer()
                    Text(state.config.detectionSource == .motion ? "Motion sensor" : "Microphone")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                LevelMeter(model: state.levelModel).frame(height: 6)
                Text(state.lastKnock)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Divider().opacity(0.6)
                HStack {
                    Text("Sensitivity").font(.caption.weight(.medium))
                    Spacer()
                    Text(sensitivityLabel(state.config.sensitivity)).font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: $state.config.sensitivity, in: 0...1)
                    .controlSize(.small)
            }
        }
    }

    // MARK: Recent activity

    private var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                CardTitle("Recent", icon: "clock")
                ForEach(state.log.prefix(3)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 54, alignment: .leading)
                        Text(entry.text).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            UpdateStatusNote(updater: state.updater)
            HStack(spacing: 4) {
                FooterButton(title: "Settings", icon: "gearshape") { SettingsWindowController.shared.show(state: state) }
                UpdateFooterButton(updater: state.updater)
                Spacer()
                FooterButton(title: "Quit", icon: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Building blocks

/// A soft rounded panel used to group things in the menu.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct CardTitle: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

/// One-line notice with an action, e.g. a permission problem or a tip.
struct NoticeRow: View {
    let icon: String
    let tint: Color
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

struct StatusLine: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var color: Color {
        if !state.config.enabled { return .gray }
        if state.config.detectionSource == .motion {
            if state.training != nil { return .orange }
            switch state.motionState {
            case .streaming: return .green
            case .connecting, .stopped: return .yellow
            default: return .red
            }
        }
        if state.micStatus == .denied || state.engineError != nil || state.micProblem != nil { return .red }
        if state.training != nil { return .orange }
        return state.listening ? .green : .yellow
    }

    private var text: String {
        if !state.config.enabled { return "Paused" }
        if state.config.detectionSource == .motion, state.training == nil, !state.testMode {
            switch state.motionState {
            case .streaming: return "Feeling for knocks (motion sensor)"
            case .stopped, .connecting: return "Connecting to the motion sensor…"
            case .helperNotRunning: return "Motion helper not installed — see Settings"
            case .noSensor: return "No motion sensor found on this Mac"
            case .helperOutdated: return "Motion helper needs an update — see Settings"
            case .error(let message): return message
            }
        }
        if state.micStatus == .denied { return "Microphone access denied" }
        if state.micProblem != nil { return "Microphone isn't sending sound" }
        if let error = state.engineError { return error }
        if let session = state.training {
            let target = session.zoneID == nil ? "your knock" : "“\(state.zoneName(session.zoneID) ?? "area")”"
            return "Training \(target) — knock \(session.remaining) more"
        }
        if state.testMode { return "Test mode — actions won't run" }
        return state.listening ? "Listening for knocks" : "Starting…"
    }
}

struct LevelMeter: View {
    @ObservedObject var model: LevelModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.65), Color.accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * normalized)
                    .animation(.linear(duration: 0.08), value: normalized)
            }
        }
        .accessibilityLabel("Microphone level")
    }

    private var normalized: CGFloat {
        let db = 20 * log10(max(Double(model.level), 1e-6))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}

func sensitivityLabel(_ value: Double) -> String {
    switch value {
    case ..<0.25: return "Hard knocks only"
    case ..<0.5: return "Firm knocks"
    case ..<0.75: return "Normal knocks"
    default: return "Light taps"
    }
}
