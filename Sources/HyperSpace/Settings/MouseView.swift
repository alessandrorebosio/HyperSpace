import SwiftUI

/// The Mouse page: scroll direction and the actions of the extra buttons.
struct MouseView: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Form {
            PageHero(page: .mouse)
            PermissionNotice()

            Section {
                SwitchRow(title: "Reverse scroll wheel", detail: "Wheel mice only: trackpads keep the system direction.",
                          isOn: model.reverseScroll, set: model.setReverseScroll)
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
                RuleArrow()
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
                    RuleArrow()
                    actionCap
                }
            }
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
            ActionChoiceMenu(ruleID: rule.id) { model.setAction($0, for: rule.id) }
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

/// The ready-made actions for a mouse button, grouped. The list never changes, so the menu
/// is only built again for another rule (`==` compares the rule), not on every redraw.
private struct ActionChoiceMenu: View, Equatable {
    let ruleID: UUID
    /// Called with the action's config text; the same for a given rule.
    let choose: (String) -> Void

    static func == (a: Self, b: Self) -> Bool { a.ruleID == b.ruleID }

    var body: some View {
        ChoiceMenu(help: "Choose an action") {
            ForEach(MouseModel.presets, id: \.group) { group in
                Menu(group.group) {
                    ForEach(group.items, id: \.action) { item in
                        Button(item.name) { choose(item.action) }
                    }
                }
            }
            Divider()
            Button("Disable Button") { choose("none") }
        }
    }
}
