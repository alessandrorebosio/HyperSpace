import SwiftUI

struct RemapView: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        Form {
            Section {
                if model.keyboards.isEmpty {
                    Text("No keyboards found").foregroundStyle(.secondary)
                }
                ForEach(model.keyboards, id: \.self) { keyboard in
                    LabeledContent {
                        Text(keyboard.builtIn ? "Built-in" : "External").foregroundStyle(.secondary)
                    } label: {
                        Label(keyboard.product.isEmpty ? "Keyboard" : keyboard.product,
                              systemImage: keyboard.builtIn ? "laptopcomputer" : "keyboard")
                    }
                }
            } header: {
                Text("Connected Keyboards")
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
                    Label("Add Remap", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
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

private struct RuleRow: View {
    @ObservedObject var model: RemapModel
    let rule: RemapModel.Rule

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(text: sourceText, width: 150, placeholder: rule.from.isEmpty, active: model.capturing == .from(rule.id)) {
                toggle(.from(rule.id))
            }
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            KeyCap(text: targetText, width: 150, placeholder: rule.to.isEmpty, active: model.capturing == .to(rule.id)) {
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
