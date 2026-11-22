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
                    MouseRuleRow(model: model, capture: model.capture, rule: rule, warning: model.warning(for: rule))
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
    let model: MouseModel
    @ObservedObject var capture: FieldCapture<MouseModel.Field>
    let rule: MouseModel.Rule
    /// The duplicate warning depends on the other rules: handed in as a value, so a change
    /// of theirs redraws the row.
    let warning: String?

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
        KeyCap(label: "Mouse button", text: buttonText, symbol: "computermouse", minWidth: Metrics.buttonCapWidth,
               placeholder: rule.button == nil, active: capture.field == .button(rule.id)) {
            model.toggleCapture(.button(rule.id))
        }
    }

    private var actionCap: some View {
        HStack(spacing: Metrics.ruleSpacing) {
            KeyCap(label: "Action of \(name)", text: actionText, minWidth: Metrics.actionCapWidth, placeholder: rule.action.isEmpty,
                   active: capture.field == .action(rule.id)) {
                model.toggleCapture(.action(rule.id))
            }
            GroupedChoiceMenu(id: rule.id, help: "Choose an action", groups: MouseModel.presetGroups,
                              last: (label: "Disable Button", value: "none")) { model.setAction($0, for: rule.id) }
                .equatable()
        }
    }

    private var trailing: some View {
        RuleTrailing(warning: warning, what: "the mapping of \(name)") { model.remove(rule.id) }
    }

    /// The button's name, for VoiceOver.
    private var name: String {
        rule.button == nil ? "the new button" : MouseModel.buttonLabel(rule)
    }

    private var buttonText: String {
        if capture.field == .button(rule.id) { return "Click a button here…" }
        return rule.button == nil ? "Button" : MouseModel.buttonLabel(rule)
    }

    private var actionText: String {
        if capture.field == .action(rule.id) { return Wording.pressKeys }
        return rule.action.isEmpty ? "Action" : MouseModel.actionLabel(rule.action)
    }
}

extension MouseModel {
    /// The ready-made actions, grouped for a menu (a mouse button's, a trackpad corner's), built once.
    static let presetGroups = presets.map { group in
        ChoiceGroup(title: group.group, items: group.items.map { (label: $0.name, value: $0.action) })
    }
}
