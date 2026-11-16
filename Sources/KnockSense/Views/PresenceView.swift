import SwiftUI
import KnockCore

/// Settings ▸ Presence: sonar test and "lock when I walk away" (experimental).
struct PresenceView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Sonar presence", systemImage: "dot.radiowaves.left.and.right").font(.headline)
                        Text("EXPERIMENTAL")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                    Text("Like a bat, your Mac plays a 19.5 kHz tone through its speakers (too high for most adults to hear) and listens to the echo. Anyone in front of the Mac, even sitting still and breathing, changes the echo slightly. No camera, no phone. First run the test to see whether it works on your Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("1. Test sonar on this Mac") {
                SonarTestCard()
            }

            Section("2. Lock when I walk away") {
                Toggle("Lock my Mac when I walk away", isOn: $state.config.presence.lockWhenAway)
                    .disabled(!state.config.presence.canLock)
                if !state.config.presence.canLock {
                    Text("Available after a successful sonar test.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Lock after I've been away for")
                        Spacer()
                        Text("\(Int(state.config.presence.awaySeconds)) s").foregroundStyle(.secondary)
                    }
                    Slider(value: $state.config.presence.awaySeconds, in: 10...180, step: 5)
                }
                Toggle("Wake the screen when I come back (ready for Touch ID)", isOn: $state.config.presence.wakeOnReturn)
                Text("Using the keyboard or trackpad always counts as being here. The tone only plays while this is on. It needs sound from the Mac's own speakers at a reasonable volume; children and pets may hear very high tones.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reading = state.sonarReading {
                Section("Live sonar") {
                    SonarMeter(title: "Echo strength", value: reading.toneLevel, low: 0.0003, high: 0.2,
                               detail: reading.toneLevel < 0.0005 ? "Too weak, turn the volume up" : "OK")
                    SonarMeter(title: "Movement in front of the Mac", value: reading.motion, low: 1e-7, high: 1e-1,
                               detail: movementDetail(reading.motion))
                    if state.config.presence.lockWhenAway && state.config.presence.canLock {
                        Label(state.someonePresent ? "You're here" : "Away", systemImage: state.someonePresent ? "person.fill" : "person.slash")
                            .foregroundStyle(state.someonePresent ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func movementDetail(_ motion: Double) -> String {
        guard let threshold = state.config.presence.testResult?.threshold else { return String(format: "%.1e", motion) }
        return motion > threshold ? "Someone's there" : "Still / empty"
    }
}

/// The guided test: instructions, countdown and the verdict.
private struct SonarTestCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.sonarTest {
        case .idle:
            intro
        case .finished(let result):
            VStack(alignment: .leading, spacing: 10) {
                Label(result.works ? "Sonar works on your Mac" : "Sonar didn't work on this Mac",
                      systemImage: result.works ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(result.works ? Color.green : Color.red)
                Text(result.message).fixedSize(horizontal: false, vertical: true)
                Text(String(format: "Echo strength %.4f · difference %.1f×", result.toneLevel, result.separation))
                    .font(.caption).foregroundStyle(.secondary)
                if let details = result.details {
                    Text(details)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Run the Test Again") { state.startSonarTest() }
            }
        case .preparing:
            running("Getting ready…", "Stay in front of your Mac.", nil)
        case .sitting(let left):
            running("Sit normally in front of your Mac", "Breathe, look at the screen, move a little as you normally would.", left)
        case .leaving(let left):
            running("Now walk away", "Go at least 3 metres away, out of sight of the screen.", left)
        case .away(let left):
            running("Stay away…", "Measuring the empty room. Come back when you hear the second chime.", left)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Takes about 30 seconds:")
            Text("① Sit in front of your Mac for 8 seconds.\n② When you hear a chime, walk away (3+ metres) and stay away.\n③ When you hear the second chime, come back and see the result.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Do it when nobody else is moving near the Mac. The volume is raised to 50% during the test if needed, then put back.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start Sonar Test") { state.startSonarTest() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func running(_ title: String, _ subtitle: String, _ secondsLeft: Int?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            if let secondsLeft {
                Text("\(secondsLeft)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 70)
            } else {
                ProgressView().frame(width: 70)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Cancel Test") { state.cancelSonarTest() }.padding(.top, 4)
            }
        }
    }
}

/// A logarithmic level bar.
private struct SonarMeter: View {
    let title: String
    let value: Double
    let low: Double
    let high: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).font(.caption)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * fraction)
                        .animation(.easeOut(duration: 0.2), value: fraction)
                }
            }
            .frame(height: 6)
        }
    }

    private var fraction: CGFloat {
        guard value > 0 else { return 0 }
        let f = (log10(value) - log10(low)) / (log10(high) - log10(low))
        return CGFloat(min(max(f, 0), 1))
    }
}
