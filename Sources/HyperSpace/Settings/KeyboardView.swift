import SwiftUI

/// The Keyboard page: the keyboard lock and the key remaps.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        Form {
            PageHero(page: .keyboard)
            PermissionNotice(detail: "Remapping one key to another already works. Combinations (the hyper key, ⌃⌥⇧…) and the keyboard lock need HyperSpace to be allowed in Privacy & Security → Accessibility.")
            SaveErrorNotice(status: model.saveStatus)

            Section {
                KeyboardLockRow(model: model, countdown: model.unlockCountdown)
                SettingRow(title: "Unlock automatically", detail: "When nobody unlocks it with the mouse first.") {
                    Picker("Unlock automatically", selection: Binding(get: { model.lockMinutes }, set: { model.setLockMinutes($0) })) {
                        ForEach(KeyboardLock.choices, id: \.self) { Text(KeyboardLock.label(minutes: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(model.isKeyboardLocked)
            } header: {
                Text("Keyboard Lock")
            } footer: {
                SectionFooter("While locked every key is ignored, media keys included. Unlock with the mouse, here or from the menu bar. Quitting HyperSpace unlocks it too.")
            }

            Section {
                if model.rules.isEmpty {
                    EmptyRow(symbol: "keyboard", text: "No remaps: every key types what it shows")
                }
                ForEach(model.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
            } header: {
                SectionHeader(title: "Remaps") {
                    AddButton(title: "Add Remap") { model.addRule() }
                }
            } footer: {
                SectionFooter("Click a key cap and press the key: a new remap then goes on to what it becomes. For a combination, hold the keys together and release them. Every key is recorded, Esc too: click the cap again to cancel.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The lock's state, with the one button that changes it.
private struct KeyboardLockRow: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var countdown: UnlockCountdown
    @Environment(\.permissionMissing) private var permissionMissing

    var body: some View {
        HStack(spacing: 12) {
            PageIcon(symbol: model.isKeyboardLocked ? "lock.fill" : "lock.open.fill",
                     color: model.isKeyboardLocked ? .orange : .gray, size: 28)
            RowLabel(model.isKeyboardLocked ? "Keyboard locked" : "Keyboard active", detail: detail)
                .monospacedDigit()
            Spacer(minLength: 12)
            if model.isKeyboardLocked {
                Button("Unlock Keyboard") { model.setKeyboardLocked(false) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Lock Keyboard") { model.setKeyboardLocked(true) }
                    // Without the event tap a lock would only claim to be on.
                    .disabled(permissionMissing)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard model.isKeyboardLocked else { return "Lock it to clean it without typing anything." }
        if let left = countdown.text { return "Unlocks by itself in \(left)." }
        return "Click Unlock Keyboard to type again."
    }
}

/// One remap: physical key → what it becomes, on which keyboards. On one line when it fits,
/// otherwise the keys on the first line and the keyboard under them.
private struct RuleRow: View {
    @ObservedObject var model: KeyboardModel
    let rule: KeyboardModel.Rule

    var body: some View {
        RuleRowLayout(secondAtEnd: true, spacing: 10, secondLabel: "On") {
            keys
        } second: {
            keyboardPicker
        } trailing: {
            trailing
        }
    }

    private var keys: some View {
        HStack(spacing: 8) {
            KeyCap(text: sourceText, minWidth: 96, placeholder: rule.from.isEmpty, active: model.capturing == .from(rule.id)) {
                model.toggleCapture(.from(rule.id))
            }
            RuleArrow()
            KeyCap(text: targetText, minWidth: 96, placeholder: rule.to.isEmpty, active: model.capturing == .to(rule.id)) {
                model.toggleCapture(.to(rule.id))
            }
            GroupedChoiceMenu(ruleID: rule.id, help: "Choose from all keys", groups: Self.keyGroups) { model.setTarget($0, for: rule.id) }
                .equatable()
        }
    }

    private var keyboardPicker: some View {
        Picker("Keyboards", selection: Binding(get: { rule.keyboard }, set: { model.setKeyboard($0, for: rule.id) })) {
            ForEach(model.keyboardOptions(for: rule), id: \.self) { option in
                Text(KeyboardModel.keyboardLabel(option)).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Which keyboards this remap applies to")
    }

    private var trailing: some View {
        RuleTrailing(warning: model.warning(for: rule)) { model.remove(rule.id) }
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
}

extension RuleRow {
    /// Every named key, grouped, to pick a remap's target from: about 130 items, built once.
    static let keyGroups = KeyCodes.groups.map { group in
        ChoiceGroup(title: group.title, items: group.keys.map { (label: $0.label, value: $0.name) })
    }
}
