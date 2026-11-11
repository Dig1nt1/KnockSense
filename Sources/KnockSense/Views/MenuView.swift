import SwiftUI
import KnockCore

struct MenuView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(Color.accentColor)
                Text("KnockSense").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $state.config.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            StatusLine()

            LevelMeter(model: state.levelModel)
                .frame(height: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(sensitivityLabel(state.config.sensitivity)).foregroundStyle(.secondary)
                }
                .font(.caption)
                Slider(value: $state.config.sensitivity, in: 0...1)
            }

            Text(state.lastKnock)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if state.canMarkLastAsNotMe {
                Button {
                    state.markLastAsNotMe()
                } label: {
                    Label("That wasn't me — ignore sounds like that", systemImage: "hand.raised")
                }
                .font(.caption)
                .help("Teaches KnockSense that the sound which just ran an action wasn't your knock.")
            }

            if state.config.verifyKnocks && state.trainedKnockCount < KnockVerifier.minimumSamples && state.training == nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Doors or other noises setting it off? Teach KnockSense your knock (8 knocks).")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Teach My Knock") { state.startKnockTraining() }
                            .font(.caption)
                    }
                }
            }

            if !state.log.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.log.prefix(4)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.date, style: .time).foregroundStyle(.tertiary)
                            Text(entry.text).lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()
            UpdateControls(updater: state.updater, compact: true)
            Divider()
            HStack {
                Button("Settings…") { SettingsWindowController.shared.show(state: state) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
    }
}

struct StatusLine: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption)
            Spacer()
            if state.config.detectionSource == .microphone && state.micStatus == .denied {
                Button("Open Settings") { Permissions.openMicrophoneSettings() }
                    .font(.caption)
            }
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
        if state.micStatus == .denied || state.engineError != nil { return .red }
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
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
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
