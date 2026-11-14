import SwiftUI

/// The Mouse page: scroll direction and the actions of the extra buttons.
struct MouseView: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Form {
            PageHero(page: .mouse)
            PermissionNotice()
            SaveErrorNotice(status: model.saveStatus)

            Section {
                SwitchRow(title: "Reverse scroll wheel", detail: "Wheel mice only: trackpads keep the system direction.",
                          isOn: model.reverseScroll, set: model.setReverseScroll)
            } header: {
                Text("Scrolling")
            }

            Section {
                if model.rules.isEmpty {
                    EmptyRow(symbol: "computermouse", text: "No buttons mapped: each does what the app makes of it")
                }
                ForEach(model.rules) { rule in
                    MouseRuleRow(model: model, rule: rule)
                }
            } header: {
                SectionHeader(title: "Buttons") {
                    AddButton(title: "Add Button") { model.addRule() }
                }
            } footer: {
                SectionFooter("Click the mouse button over this window (hold modifiers to include them), then press the keys it should send or pick an action from the menu. Esc cancels, Delete disables the button.")
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
        RuleRowLayout {
            buttonCap
        } second: {
            RuleArrow()
            actionCap
        } trailing: {
            trailing
        }
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
            GroupedChoiceMenu(ruleID: rule.id, help: "Choose an action", groups: Self.actionGroups,
                              last: (label: "Disable Button", value: "none")) { model.setAction($0, for: rule.id) }
                .equatable()
        }
    }

    private var trailing: some View {
        RuleTrailing(warning: model.warning(for: rule)) { model.remove(rule.id) }
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

extension MouseRuleRow {
    /// The ready-made actions for a mouse button, grouped, built once.
    static let actionGroups = MouseModel.presets.map { group in
        ChoiceGroup(title: group.group, items: group.items.map { (label: $0.name, value: $0.action) })
    }
}
