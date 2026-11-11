import SwiftUI
import UniformTypeIdentifiers
import KnockCore

struct RulesView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Knock actions").font(.title2.bold())
                    Text("Choose what happens when you knock on your Mac. A rule for a specific area beats an “anywhere” rule.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    editing = Rule(name: "", knockCount: 2, action: .builtin(.playPause))
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if state.config.rules.isEmpty {
                Spacer()
                Text("No actions yet. Click “Add Action” to create one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(state.config.rules) { rule in
                        RuleRow(rule: rule, onEdit: { editing = rule })
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .sheet(item: $editing) { rule in
            RuleEditor(draft: rule, isNew: !state.config.rules.contains { $0.id == rule.id }) { saved in
                state.upsert(saved)
            }
            .environmentObject(state)
        }
    }
}

struct RuleRow: View {
    @EnvironmentObject var state: AppState
    let rule: Rule
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Enabled", isOn: enabledBinding)
                .labelsHidden()
            KnockBadge(count: rule.knockCount)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.body.weight(.medium))
                Text("\(rule.knockCount) knock\(rule.knockCount == 1 ? "" : "s") · \(state.zoneName(rule.zoneID) ?? "anywhere") → \(rule.action.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Test") { ActionRunner.run(rule.action) }
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .help("Edit")
            Button(role: .destructive) { state.deleteRule(rule.id) } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.5)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in
                var updated = rule
                updated.enabled = newValue
                state.upsert(updated)
            }
        )
    }
}

struct KnockBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 34)
    }
}

struct RuleEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var draft: Rule
    let isNew: Bool
    let onSave: (Rule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New knock action" : "Edit knock action").font(.title2.bold())

            Form {
                TextField("Name", text: $draft.name, prompt: Text(draft.action.summary))

                Picker("When I knock", selection: $draft.knockCount) {
                    ForEach(1...4, id: \.self) { n in
                        Text(n == 1 ? "Once" : n == 2 ? "Twice" : "\(n) times").tag(n)
                    }
                }

                Picker("On", selection: $draft.zoneID) {
                    Text("Anywhere on the Mac").tag(Optional<UUID>.none)
                    ForEach(state.config.zones) { zone in
                        Text(zone.name).tag(Optional(zone.id))
                    }
                }
                if state.config.zones.isEmpty {
                    Text("Tip: teach KnockSense specific spots in the Areas tab to use different actions per area.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Picker("Do", selection: $draft.action.kind) {
                    ForEach(ActionKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .onChange(of: draft.action.kind) { kind in
                    draft.action.argument = kind == .builtin ? BuiltinAction.playPause.rawValue : ""
                }

                argumentEditor

                if draft.knockCount == 1 {
                    Text("Single knocks are easy to trigger by accident (bumping the desk). Double or triple knocks are more reliable.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Test Action") { ActionRunner.run(draft.action) }
                    .disabled(!draft.action.isConfigured)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var rule = draft
                    if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.action.summary }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.action.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var argumentEditor: some View {
        switch draft.action.kind {
        case .builtin:
            Picker("Action", selection: $draft.action.argument) {
                ForEach(BuiltinAction.allCases) { action in Text(action.title).tag(action.rawValue) }
            }
        case .openApp:
            HStack {
                TextField("App", text: $draft.action.argument, prompt: Text(draft.action.kind.placeholder))
                Button("Choose…", action: chooseApp)
            }
        case .shell, .appleScript:
            VStack(alignment: .leading) {
                Text(draft.action.kind == .shell ? "Command (runs in zsh)" : "AppleScript")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.action.argument)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("Example: \(draft.action.kind.placeholder)").font(.caption).foregroundStyle(.secondary)
            }
        case .openURL, .shortcut:
            TextField(draft.action.kind == .openURL ? "Address" : "Shortcut",
                      text: $draft.action.argument,
                      prompt: Text(draft.action.kind.placeholder))
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.action.argument = url.path
        }
    }
}
