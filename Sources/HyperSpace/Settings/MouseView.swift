import SwiftUI

/// The Mouse page: scroll direction and the actions of the extra buttons.
struct MouseView: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Form {
            PageHero(page: .mouse)
            PermissionNotice()

            Section {
                SettingRow(title: "Reverse scroll wheel", detail: "Wheel mice only: trackpads keep the system direction.") {
                    Toggle("Reverse scroll wheel", isOn: Binding(get: { model.reverseScroll }, set: { model.setReverseScroll($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            } header: {
                Text("Scrolling")
            }

            Section {
                if model.rules.isEmpty {
                    EmptyRow(symbol: "computermouse", text: "No buttons mapped yet")
                }
                ForEach(model.rules) { rule in
                    MouseRuleRow(model: model, rule: rule)
                }
            } header: {
                SectionHeader(title: "Buttons") {
                    AddButton(title: "Add Button") { model.addRule() }
                }
            } footer: {
                SectionFooter(
                    "Click the mouse button over this window (hold modifiers to include them), then press the keys it should send or pick an action from the menu.",
                    error: model.saveError
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// One mapping: button (with modifiers) → action. On one line when it fits, otherwise the
/// button on the first line and its action under it.
private struct MouseRuleRow: View {
    @ObservedObject var model: MouseModel
    let rule: MouseModel.Rule

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttonCap
                arrow
                actionCap
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    buttonCap
                    Spacer(minLength: 12)
                    trailing
                }
                HStack(spacing: 8) {
                    arrow
                    actionCap
                }
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private var buttonCap: some View {
        KeyCap(text: buttonText, symbol: "computermouse", minWidth: 140, placeholder: rule.button == nil,
               active: model.capturing == .button(rule.id)) {
            model.toggleCapture(.button(rule.id))
        }
    }

    private var actionCap: some View {
        HStack(spacing: 8) {
            KeyCap(text: actionText, minWidth: 110, placeholder: rule.action.isEmpty, active: model.capturing == .action(rule.id)) {
                model.toggleCapture(.action(rule.id))
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
}
