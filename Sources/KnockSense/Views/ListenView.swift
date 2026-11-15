import SwiftUI
import KnockCore

/// Settings ▸ Listen: "Someone's calling you" and auto-duck.
struct ListenView: View {
    @EnvironmentObject var state: AppState

    private var settings: Binding<ListenSettings> { $state.config.listen }

    var body: some View {
        Form {
            Section {
                Text("For when you're wearing headphones. KnockSense uses your Mac's microphone to notice when someone calls your name or talks to you. Speech is recognised offline, on your Mac, and is never recorded or sent anywhere.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Only while I'm wearing headphones", isOn: settings.headphonesOnly)
                    Text("Recommended. Through speakers, your Mac would hear its own music and voices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Someone's calling you") {
                Toggle("Tell me when someone says my name", isOn: nameAlertBinding)
                TextField("My name and nicknames", text: settings.names, prompt: Text("e.g. Diganta, Dig"))
                Picker("Language", selection: settings.localeID) {
                    Text("Same as my Mac").tag("")
                    Text("English (India)").tag("en-IN")
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("Hindi").tag("hi-IN")
                }
                Toggle("Pause music and turn other sound down", isOn: settings.pauseMusicOnName)
                if let problem = state.listenProblem, state.config.listen.nameAlertEnabled {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.config.listen.nameAlertEnabled && !state.config.listen.nameList.isEmpty {
                    Label("Listening for: \(state.config.listen.nameList.joined(separator: ", "))", systemImage: "ear")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show a Test Alert") { state.simulateNameAlert() }
                    Text("Shows the banner, plays the sound and pauses music, like the real thing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Turn the volume down when someone talks to me") {
                Toggle("Lower the volume while someone talks near me", isOn: settings.autoDuckEnabled)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Lower to")
                        Spacer()
                        Text("\(Int(state.config.listen.duckLevel * 100))% of the volume").foregroundStyle(.secondary)
                    }
                    Slider(value: settings.duckLevel, in: 0.05...0.6)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Voices to react to")
                        Spacer()
                        Text(state.config.listen.duckSensitivity < 0.35 ? "Close and loud only"
                             : state.config.listen.duckSensitivity < 0.7 ? "Normal conversation" : "Quieter voices too")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: settings.duckSensitivity, in: 0...1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Not while I'm on a call", isOn: settings.pauseDuckingDuringCalls)
                    Text("Your own voice on a Zoom, FaceTime or Teams call won't turn the call down. Needs macOS 14 or later.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.config.listen.autoDuckEnabled {
                    Label(state.someoneTalking ? "Someone is talking — volume lowered" : "Waiting for someone to talk",
                          systemImage: state.someoneTalking ? "person.wave.2.fill" : "person.wave.2")
                        .foregroundStyle(state.someoneTalking ? Color.accentColor : Color.secondary)
                }
            }

            if state.micStatus == .denied {
                Section {
                    Label("These features need the microphone, which is turned off for KnockSense.", systemImage: "mic.slash")
                        .foregroundStyle(.red)
                    Button("Open Privacy Settings") { Permissions.openMicrophoneSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var nameAlertBinding: Binding<Bool> {
        Binding(get: { state.config.listen.nameAlertEnabled }, set: { state.setNameAlert($0) })
    }
}
