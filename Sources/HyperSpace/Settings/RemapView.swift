import SwiftUI

struct RemapView: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        Form {
            PageHeader()
            Section {
                KeyboardLockRow(model: model)
            } header: {
                Text("Keyboard Lock")
            } footer: {
                SectionFooter("Every key is ignored, media keys included, until you unlock with the mouse (here or from the menu bar) or the time is up.")
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
                    hint: "Click a key, then press it. For a combination, hold the keys together and release.",
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
            SidebarIcon(symbol: model.isKeyboardLocked ? "lock.fill" : "keyboard.fill",
                        color: model.isKeyboardLocked ? .orange : SettingsNavigation.Page.keyboard.color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isKeyboardLocked ? "Keyboard locked" : "Keyboard active").font(.headline)
                Text(lockDetail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
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
        Picker("Unlock automatically", selection: Binding(get: { model.lockMinutes }, set: { model.lockMinutes = $0 })) {
            ForEach(KeyboardLock.choices, id: \.self) { Text(KeyboardLock.label(minutes: $0)).tag($0) }
        }
        .disabled(model.isKeyboardLocked)
    }

    private var lockDetail: String {
        guard model.isKeyboardLocked else { return "Ignore every key, for instance to clean it." }
        if let left = model.unlocksIn { return "Unlocks by itself in \(left)." }
        return "Click Unlock to type again."
    }
}

private struct RuleRow: View {
    @ObservedObject var model: RemapModel
    let rule: RemapModel.Rule

    /// One line when it fits; otherwise the keys on the first line and the keyboard under them.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                keys
                Spacer(minLength: 12)
                keyboardPicker
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    keys
                    Spacer(minLength: 12)
                    trailing
                }
                HStack(spacing: 8) {
                    Text("Keyboard").foregroundStyle(.secondary)
                    keyboardPicker
                }
            }
        }
    }

    private var keys: some View {
        HStack(spacing: 10) {
            KeyCap(text: sourceText, minWidth: 110, placeholder: rule.from.isEmpty, active: model.capturing == .from(rule.id)) {
                toggle(.from(rule.id))
            }
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            KeyCap(text: targetText, minWidth: 110, placeholder: rule.to.isEmpty, active: model.capturing == .to(rule.id)) {
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
        }
    }

    private var keyboardPicker: some View {
        Picker("Keyboards", selection: Binding(get: { rule.keyboard }, set: { model.setKeyboard($0, for: rule.id) })) {
            ForEach(model.keyboardOptions(for: rule), id: \.self) { option in
                Text(model.keyboardLabel(option)).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var trailing: some View {
        HStack(spacing: 8) {
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
