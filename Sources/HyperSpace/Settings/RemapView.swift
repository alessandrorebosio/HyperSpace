import SwiftUI

/// The Keyboard page: the keyboard lock and the key remaps.
struct RemapView: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        Form {
            PageHero(page: .keyboard)

            Section {
                KeyboardLockRow(model: model)
                Picker(selection: $model.lockMinutes) {
                    ForEach(KeyboardLock.choices, id: \.self) { Text(KeyboardLock.label(minutes: $0)).tag($0) }
                } label: {
                    RowLabel("Unlock automatically", detail: "When nobody unlocks it with the mouse first.")
                }
                .disabled(model.isKeyboardLocked)
            } header: {
                Text("Keyboard Lock")
            } footer: {
                SectionFooter("While locked every key is ignored, media keys included. Unlock with the mouse, here or from the menu bar. Quitting HyperSpace unlocks it too.")
            }

            Section {
                if model.rules.isEmpty {
                    EmptyRow(symbol: "keyboard", text: "No remaps yet")
                }
                ForEach(model.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
            } header: {
                SectionHeader(title: "Remaps") {
                    AddButton(title: "Add Remap") { model.addRule() }
                }
            } footer: {
                SettingsFooter(
                    hint: "Click a key cap, then press the key. For a combination, hold the keys together and release them.",
                    error: model.saveError
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// The lock's state, with the one button that changes it.
private struct KeyboardLockRow: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        HStack(spacing: 12) {
            PageIcon(symbol: model.isKeyboardLocked ? "lock.fill" : "lock.open.fill",
                     color: model.isKeyboardLocked ? .orange : .gray, size: 28)
            RowLabel(model.isKeyboardLocked ? "Keyboard locked" : "Keyboard active", detail: detail)
                .monospacedDigit()
            Spacer(minLength: 12)
            if model.isKeyboardLocked {
                Button("Unlock") { model.setKeyboardLocked(false) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Lock Keyboard") { model.setKeyboardLocked(true) }
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard model.isKeyboardLocked else { return "Lock it to clean it without typing anything." }
        if let left = model.unlocksIn { return "Unlocks by itself in \(left)." }
        return "Click Unlock to type again."
    }
}

/// One remap: physical key → what it becomes, on which keyboards. On one line when it fits,
/// otherwise the keys on the first line and the keyboard under them.
private struct RuleRow: View {
    @ObservedObject var model: RemapModel
    let rule: RemapModel.Rule

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
                    Text("On").foregroundStyle(.secondary)
                    keyboardPicker
                }
            }
        }
    }

    private var keys: some View {
        HStack(spacing: 8) {
            KeyCap(text: sourceText, minWidth: 96, placeholder: rule.from.isEmpty, active: model.capturing == .from(rule.id)) {
                toggle(.from(rule.id))
            }
            Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            KeyCap(text: targetText, minWidth: 96, placeholder: rule.to.isEmpty, active: model.capturing == .to(rule.id)) {
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
        .help("Which keyboards this remap applies to")
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
