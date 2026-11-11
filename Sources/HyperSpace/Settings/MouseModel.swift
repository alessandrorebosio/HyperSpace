import AppKit
import Combine

/// State of the mouse settings. Every change is written to config.json at once;
/// the config watcher then applies it to the event tap.
final class MouseModel: ObservableObject, FileBackedModel {
    struct Rule: Identifiable, Equatable {
        let id = UUID()
        /// CGEvent button number: 2 = middle, 3 = back, 4 = forward, …
        var button: Int?
        var modifiers: Modifiers
        /// An action string: "key cmd+left_bracket", "none", or anything from the config.
        var action: String
        /// Modifiers as written in the file when they do not parse: written back as they were,
        /// not dropped (which would make the rule fire without them), until the button is recorded again.
        var invalidModifiers: String?

        var isComplete: Bool { button != nil && !action.isEmpty }
    }

    enum Field: Equatable {
        case button(UUID)
        case action(UUID)
    }

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var reverseScroll = TapConfig.defaultReverseScroll
    @Published private(set) var capturing: Field?
    @Published private(set) var saveError: String?

    private let eventTap: EventTap
    private let monitor = LocalEventMonitor()
    private var synced = SyncedSlice(sections: "mouse")
    /// The scroll setting as loaded: written only once it changes.
    private var loadedReverseScroll: Bool?

    /// `config`: the file as `ConfigWriter.read()` returns it.
    init(eventTap: EventTap, config: [String: Any]) {
        self.eventTap = eventTap
        load(config)
    }

    func reload(from root: [String: Any]) {
        guard capturing == nil, synced.changed(in: root) else { return }
        load(root)
    }

    deinit {
        stopCapture()
    }

    // MARK: - Editing

    func addRule() {
        let rule = Rule(button: nil, modifiers: [], action: "")
        rules.append(rule)
        startCapture(.button(rule.id))
    }

    func remove(_ id: UUID) {
        if capturing == .button(id) || capturing == .action(id) { stopCapture() }
        rules.removeAll { $0.id == id }
        save()
    }

    /// Ready-made actions for mouse buttons, grouped for the menu.
    static let presets: [(group: String, items: [(name: String, action: String)])] = [
        ("Navigation", [
            ("Back", "navigate back"),
            ("Forward", "navigate forward"),
        ]),
        ("Browser", [
            ("Open Link in New Tab", "click cmd"),
            ("Reload Page", "key cmd+r"),
            ("New Tab", "key cmd+t"),
            ("Close Tab", "key cmd+w"),
            ("Reopen Closed Tab", "key shift+cmd+t"),
            ("Next Tab", "key ctrl+tab"),
            ("Previous Tab", "key ctrl+shift+tab"),
        ]),
        ("Edit", [
            ("Copy", "key cmd+c"),
            ("Paste", "key cmd+v"),
            ("Cut", "key cmd+x"),
            ("Undo", "key cmd+z"),
            ("Redo", "key shift+cmd+z"),
            ("Zoom In", "key cmd+="),
            ("Zoom Out", "key cmd+-"),
        ]),
        ("System", [
            ("Mission Control", "system mission_control"),
            ("App Windows", "system app_windows"),
            ("Show Desktop", "system show_desktop"),
            ("Spotlight", "key cmd+space"),
            ("Screenshot", "key shift+cmd+5"),
            ("Toggle Full Screen", "key ctrl+cmd+f"),
            ("Lock Screen", "key ctrl+cmd+q"),
        ]),
        ("Media", [
            ("Play / Pause", "media play_pause"),
            ("Next Track", "media next"),
            ("Previous Track", "media previous"),
            ("Volume Up", "media volume_up"),
            ("Volume Down", "media volume_down"),
            ("Mute", "media mute"),
            ("Brightness Up", "media brightness_up"),
            ("Brightness Down", "media brightness_down"),
        ]),
    ]

    /// Preset names by action text, and of the key presets by parsed shortcut, built once.
    private static let presetNames: (byAction: [String: String], byCombo: [(combo: KeyCombo, name: String)]) = {
        var byAction: [String: String] = [:]
        var byCombo: [(combo: KeyCombo, name: String)] = []
        for (_, items) in presets {
            for item in items {
                if byAction[item.action] == nil { byAction[item.action] = item.name }
                if item.action.hasPrefix("key "), let combo = try? KeyCombo.parse(String(item.action.dropFirst(4))) {
                    byCombo.append((combo, item.name))
                }
            }
        }
        return (byAction, byCombo)
    }()

    /// The preset name for an action, matching key shortcuts by meaning ("cmd+[" == "cmd+left_bracket").
    private static func presetName(_ action: String) -> String? {
        if let name = presetNames.byAction[action] { return name }
        guard action.hasPrefix("key "), let combo = try? KeyCombo.parse(String(action.dropFirst(4))) else { return nil }
        return presetNames.byCombo.first { $0.combo == combo }?.name
    }

    func setReverseScroll(_ on: Bool) {
        guard reverseScroll != on else { return }
        reverseScroll = on
        save()
    }

    func warning(for rule: Rule) -> String? {
        guard rule.isComplete else { return nil }
        let duplicate = rules.contains {
            $0.id != rule.id && $0.isComplete && $0.button == rule.button && $0.modifiers == rule.modifiers
        }
        return duplicate ? "Another mapping uses the same button and modifiers" : nil
    }

    static func buttonLabel(_ rule: Rule) -> String {
        guard let button = rule.button else { return "" }
        let name: String
        switch button {
        case 2: name = "Middle Button"
        case 3: name = "Back Button"
        case 4: name = "Forward Button"
        default: name = "Button \(button + 1)"
        }
        return rule.modifiers.isEmpty ? name : "\(rule.modifiers.symbols) \(name)"
    }

    static func actionLabel(_ action: String) -> String {
        if action == "none" { return "Disabled" }
        if let name = presetName(action) { return name }
        if action.hasPrefix("key ") { return RemapTarget.label(String(action.dropFirst(4))) }
        return action
    }

    // MARK: - Capture

    /// Button: click it over the settings window (hold modifiers to include them);
    /// mappings are suspended meanwhile so the button reaches the window.
    /// Action: press the keys it should send, e.g. ⌘ and [ together.
    func startCapture(_ field: Field) {
        stopCapture()
        capturing = field
        switch field {
        case .button:
            eventTap.setButtonsSuspended(true)
            monitor.start(.otherMouseDown) { [weak self] event in
                guard let self, event.buttonNumber >= 2, event.buttonNumber < 32 else { return false }
                let modifiers = Modifiers(event.modifierFlags)
                update(field) { $0.button = event.buttonNumber; $0.modifiers = modifiers; $0.invalidModifiers = nil }
                return true
            }
        case .action:
            // A bound shortcut is recorded, not run. As on the Shortcuts page, Escape alone
            // cancels and Delete alone clears (the button then does nothing).
            eventTap.setKeyBindingsSuspended(true)
            monitor.start(.keyDown) { [weak self] event in
                guard let self else { return false }
                guard let name = KeyCodes.name(forKeyCode: event.keyCode) else {
                    NSSound.beep()
                    return true
                }
                let modifiers = Modifiers(event.modifierFlags)
                switch (name, modifiers.isEmpty) {
                case ("escape", true): stopCapture()
                case ("delete", true): update(field) { $0.action = "none" }
                default: update(field) { $0.action = "key \(modifiers.text(key: name))" }
                }
                return true
            }
        }
    }

    func stopCapture() {
        monitor.stop()
        switch capturing {
        case .button: eventTap.setButtonsSuspended(false)
        case .action: eventTap.setKeyBindingsSuspended(false)
        case nil: return
        }
        capturing = nil
    }

    private func update(_ field: Field, _ change: (inout Rule) -> Void) {
        let id: UUID
        switch field {
        case .button(let ruleID), .action(let ruleID): id = ruleID
        }
        rules.update(id: id, change)
        stopCapture()
        save()
        // A new mapping goes straight on to its action.
        if case .button = field, let rule = rules.first(where: { $0.id == id }), rule.action.isEmpty {
            startCapture(.action(id))
        }
    }

    func setAction(_ action: String, for id: UUID) {
        if capturing == .action(id) { stopCapture() }
        if rules.update(id: id, { $0.action = action }) { save() }
    }

    // MARK: - Persistence

    private func load(_ config: [String: Any]) {
        let mouse = ConfigWriter.section("mouse", of: config)
        let reverse = mouse["reverseScroll"] as? Bool ?? TapConfig.defaultReverseScroll
        if reverseScroll != reverse { reverseScroll = reverse }
        loadedReverseScroll = reverse
        // In the order of the file: when two rules share a button, the last one wins.
        rules = (mouse["buttons"] as? [[String: Any]] ?? []).map {
            let text = $0["modifiers"] as? String ?? ""
            let modifiers = try? Modifiers.parse(text)
            return Rule(button: $0["button"] as? Int, modifiers: modifiers ?? [],
                        action: $0["action"] as? String ?? "", invalidModifiers: modifiers == nil ? text : nil)
        }
        synced.record(config)
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        let error = ConfigWriter.save(recording: &synced) { root in
            ConfigWriter.edit(&root, section: "mouse") { mouse in
                // Left out until changed, like every option the user never set.
                if reverseScroll != loadedReverseScroll { mouse["reverseScroll"] = reverseScroll }
                mouse["buttons"] = complete.map { rule -> [String: Any] in
                    var entry: [String: Any] = ["button": rule.button!, "action": rule.action]
                    if let invalid = rule.invalidModifiers {
                        entry["modifiers"] = invalid
                    } else if !rule.modifiers.isEmpty {
                        entry["modifiers"] = rule.modifiers.configText
                    }
                    return entry
                }
            }
        }
        if error == nil { loadedReverseScroll = reverseScroll }
        Optional.assignChange(error, to: &saveError)
    }
}
