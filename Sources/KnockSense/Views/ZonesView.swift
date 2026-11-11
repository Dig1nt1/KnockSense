import SwiftUI
import KnockCore

struct ZonesView: View {
    @EnvironmentObject var state: AppState
    @State private var newZoneName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Knock areas").font(.title2.bold())
            Text("Optional: teach KnockSense the spots you knock on, e.g. “Left palm rest”, “Right of trackpad” or “Lid”. Add an area, click Train, then knock \(AppState.trainingKnocks) times on that spot the same way you'll knock later. Spots that are far apart and made of different parts of the case are easiest to tell apart.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("New area name", text: $newZoneName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addZone)
                Button("Add Area", action: addZone)
            }

            if state.config.zones.isEmpty {
                Spacer()
                Text("No areas yet. Without areas, every rule set to “Anywhere” runs wherever you knock.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(state.config.zones) { zone in
                        ZoneRow(zone: zone)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Test mode (show which area I knocked; don't run actions)", isOn: $state.testMode)
                    Text(state.lastKnock).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let accuracy = state.zoneAccuracy {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Self-test accuracy: \(Int((accuracy * 100).rounded()))%")
                            .font(.callout.weight(.medium))
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
        .padding(.vertical, 4)
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
