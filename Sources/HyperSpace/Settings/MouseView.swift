import SwiftUI

struct MouseView: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.reverseScroll }, set: { model.setReverseScroll($0) })) {
                    Text("Reverse scroll wheel")
                    Text("Only mice with a wheel; trackpads and Magic Mouse keep the system direction.")
                }
            } header: {
                Text("Scrolling")
            }

            Section {
                if model.rules.isEmpty {
                    Text("No button mappings yet").foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    MouseRuleRow(model: model, rule: rule)
                }
                Button {
                    model.addRule()
                } label: {
                    Label("Add Button", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Buttons")
            } footer: {
                SettingsFooter(
                    hint: "Click a mouse button over this window (hold modifiers to include them), then press the keys it should send or pick an action.",
                    error: model.saveError
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct MouseRuleRow: View {
    @ObservedObject var model: MouseModel
    let rule: MouseModel.Rule

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(text: buttonText, symbol: "computermouse", width: 190, placeholder: rule.button == nil,
                   active: model.capturing == .button(rule.id)) {
                toggle(.button(rule.id))
            }
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            KeyCap(text: actionText, width: 190, placeholder: rule.action.isEmpty, active: model.capturing == .action(rule.id)) {
                toggle(.action(rule.id))
            }
            ChoiceMenu(help: "Choose an action") {
                ForEach(MouseModel.presets, id: \.group) { group in
                    Menu(group.group) {
                        ForEach(group.items, id: \.action) { item in
                            Button(item.name) { model.choose(item.action, for: rule.id) }
                        }
                    }
                }
                Divider()
                Button("Disable Button") { model.choose("none", for: rule.id) }
            }
            Spacer(minLength: 12)
            WarningBadge(text: model.warning(for: rule))
            RemoveButton { model.remove(rule.id) }
        }
    }

    private var buttonText: String {
        if model.capturing == .button(rule.id) { return "Click a button here…" }
        return rule.button == nil ? "Button" : MouseModel.buttonLabel(rule)
    }

    private var actionText: String {
        if model.capturing == .action(rule.id) { return "Press keys…" }
        return rule.action.isEmpty ? "Action" : MouseModel.actionLabel(rule.action)
    }

    private func toggle(_ field: MouseModel.Field) {
        model.capturing == field ? model.stopCapture() : model.startCapture(field)
    }
}
