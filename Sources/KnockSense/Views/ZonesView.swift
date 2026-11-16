import SwiftUI
import KnockCore

struct ZonesView: View {
    @EnvironmentObject var state: AppState
    @State private var newZoneName = ""

    var body: some View {
        Form {
            Section {
                Text("Optional: teach KnockSense the spots you knock on, e.g. “Left palm rest”, “Right of trackpad” or “Lid”. Add an area, click Train, then knock \(AppState.trainingKnocks) times on that spot the same way you'll knock later.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("New area", text: $newZoneName, prompt: Text("e.g. Left palm rest"))
                        .onSubmit(addZone)
                    Button("Add Area", action: addZone)
                        .disabled(newZoneName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if state.config.zones.isEmpty {
                    Text("No areas yet. Without areas, every rule set to “Anywhere” runs wherever you knock.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(state.config.zones) { zone in
                        ZoneRow(zone: zone)
                    }
                }
            } header: {
                Text("Your areas")
            } footer: {
                Text("Spots that are far apart and made of different parts of the case are easiest to tell apart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Check") {
                Toggle(isOn: $state.testMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test mode")
                        Text("Shows which area you knocked on, without running actions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Last knock") {
                    Text(state.lastKnock).foregroundStyle(.secondary)
                }
                if let accuracy = state.zoneAccuracy {
                    LabeledContent("Self-test accuracy") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int((accuracy * 100).rounded()))%")
                                .fontWeight(.medium)
                                .foregroundStyle(accuracy >= 0.85 ? Color.green : accuracy >= 0.65 ? Color.orange : Color.red)
                            if accuracy < 0.85 {
                                Text("Areas sound alike. Add samples or pick spots farther apart.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addZone() {
        state.addZone(named: newZoneName)
        newZoneName = ""
    }
}

struct ZoneRow: View {
    @EnvironmentObject var state: AppState
    let zone: Zone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left.fill").foregroundStyle(Color.accentColor)
            TextField("Name", text: nameBinding)
                .textFieldStyle(.plain)
                .labelsHidden()
                .frame(maxWidth: 220)
            Text(sampleText)
                .font(.caption)
                .foregroundStyle(state.usableSampleCount(zone) >= 3 ? Color.secondary : Color.orange)
            Spacer()

            if let session = state.training, session.zoneID == zone.id {
                ProgressView(value: Double(session.total - session.remaining), total: Double(session.total))
                    .frame(width: 80)
                Text("Knock now… \(session.remaining) left").font(.caption.weight(.semibold))
                Button("Cancel") { state.training = nil }
            } else {
                Button(zone.samples.isEmpty ? "Train" : "Add Samples") { state.startTraining(zone.id) }
                    .disabled(state.training != nil)
                Menu {
                    Button("Clear Samples") { state.clearSamples(zone.id) }
                    Button("Delete Area", role: .destructive) { state.deleteZone(zone.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private var sampleText: String {
        let usable = state.usableSampleCount(zone)
        if usable < zone.samples.count {
            return "\(usable) of \(zone.samples.count) samples usable (microphone changed — retrain)"
        }
        return usable == 0 ? "Not trained" : "\(usable) sample\(usable == 1 ? "" : "s")"
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { state.config.zones.first { $0.id == zone.id }?.name ?? "" },
            set: { newValue in
                if let index = state.config.zones.firstIndex(where: { $0.id == zone.id }) {
                    state.config.zones[index].name = newValue
                }
            }
        )
    }
}
