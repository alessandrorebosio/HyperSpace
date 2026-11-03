import SwiftUI

struct MouseView: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Form {
            PageHeader()
            PermissionNotice()

            Section {
                Toggle(isOn: Binding(get: { model.reverseScroll }, set: { model.setReverseScroll($0) })) {
                    RowLabel("Reverse scroll wheel", detail: "Mice with a wheel only; trackpads and Magic Mouse keep the system direction.")
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
                    AddLabel(title: "Add Button")
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

    /// One line when it fits; otherwise the button on the first line and its action under it.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                buttonCap
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                actionCap
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    buttonCap
                    Spacer(minLength: 12)
                    trailing
                }
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    actionCap
                }
            }
        }
    }

    private var buttonCap: some View {
        KeyCap(text: buttonText, symbol: "computermouse", minWidth: 110, placeholder: rule.button == nil,
               active: model.capturing == .button(rule.id)) {
            toggle(.button(rule.id))
        }
    }

    private var actionCap: some View {
        HStack(spacing: 10) {
            KeyCap(text: actionText, minWidth: 110, placeholder: rule.action.isEmpty, active: model.capturing == .action(rule.id)) {
                toggle(.action(rule.id))
            }
            ChoiceMenu(help: "Choose an action") {
                ForEach(MouseModel.presets, id: \.group) { group in
                    Menu(group.group) {
                        ForEach(group.items, id: \.action) { item in
                            Button(item.name) { model.setAction(item.action, for: rule.id) }
                        }
                    }
                }
                Divider()
                Button("Disable Button") { model.setAction("none", for: rule.id) }
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
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
