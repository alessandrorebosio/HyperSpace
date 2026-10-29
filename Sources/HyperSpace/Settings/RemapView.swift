import SwiftUI

struct RemapView: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        Form {
            Section {
                KeyboardLockRow(model: model)
            } header: {
                Text("Keyboard Lock")
            } footer: {
                SectionFooter("Every key is ignored, media and brightness keys included, until you unlock it with the mouse — here or from the menu bar — or the chosen time is up. Handy to clean the keyboard. Quitting HyperSpace unlocks it.")
            }

            Section {
                if model.rules.isEmpty {
                    Text("No remaps yet").foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
                Button {
                    model.addRule()
                } label: {
                    AddLabel(title: "Add Remap")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Remaps")
            } footer: {
                SettingsFooter(
                    hint: "Click a key and press it on any keyboard. For a combination hold the keys together (e.g. ⇧⌃⌥) and release.",
                    error: model.saveError
                )
            }

        }
        .formStyle(.grouped)
    }
}

private struct KeyboardLockRow: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isKeyboardLocked ? "lock.fill" : "keyboard")
                .font(.title2)
                .foregroundStyle(model.isKeyboardLocked ? Color.orange : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isKeyboardLocked ? "Keyboard locked" : "Keyboard active").font(.headline)
                Text(lockDetail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Picker("Unlock", selection: Binding(get: { model.lockMinutes }, set: { model.lockMinutes = $0 })) {
                ForEach(KeyboardLock.choices, id: \.self) { Text(KeyboardLock.label(minutes: $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isKeyboardLocked)
            .help("When the keyboard unlocks by itself")
            if model.isKeyboardLocked {
                Button("Unlock") { model.setKeyboardLocked(false) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Lock Keyboard") { model.setKeyboardLocked(true) }
                    .controlSize(.large)
            }
        }
        .padding(.vertical, 4)
    }

    private var lockDetail: String {
        guard model.isKeyboardLocked else { return "Lock it to clean it without typing anything." }
        if let left = model.unlocksIn { return "Keys do nothing. Unlocks by itself in \(left)." }
        return "Keys do nothing. Click Unlock to type again."
    }
}

private struct RuleRow: View {
    @ObservedObject var model: RemapModel
    let rule: RemapModel.Rule

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(text: sourceText, width: 130, placeholder: rule.from.isEmpty, active: model.capturing == .from(rule.id)) {
                toggle(.from(rule.id))
            }
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            KeyCap(text: targetText, width: 130, placeholder: rule.to.isEmpty, active: model.capturing == .to(rule.id)) {
                toggle(.to(rule.id))
            }
            ChoiceMenu(help: "Choose from all keys") {
                ForEach(KeyCodes.groups, id: \.title) { group in
                    Menu(group.title) {
                        ForEach(group.keys, id: \.name) { key in
                            Button(key.label) { model.setTarget(key.name, for: rule.id) }
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            Picker("Keyboards", selection: Binding(get: { rule.keyboard }, set: { model.setKeyboard($0, for: rule.id) })) {
                ForEach(model.keyboardOptions(for: rule), id: \.self) { option in
                    Text(model.keyboardLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
            WarningBadge(text: model.warning(for: rule))
            RemoveButton { model.remove(rule.id) }
        }
    }

    private var sourceText: String {
        if model.capturing == .from(rule.id) { return "Press a key…" }
        return rule.from.isEmpty ? "Key" : KeyInfo.label(for: rule.from)
    }

    private var targetText: String {
        if model.capturing == .to(rule.id) {
            return model.capturePreview.isEmpty ? "Press keys…" : "\(model.capturePreview) …"
        }
        return rule.to.isEmpty ? "Becomes" : RemapTarget.label(rule.to)
    }

    private func toggle(_ field: RemapModel.Field) {
        model.capturing == field ? model.stopCapture() : model.startCapture(field)
    }
}
