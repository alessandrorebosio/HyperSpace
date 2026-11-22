import AppKit
import Combine

/// State of the mouse settings. Every change is written to config.json at once;
/// the config watcher then applies it to the event tap.
final class MouseModel: ObservableObject, FileBackedModel {
    struct Rule: Identifiable, Equatable {
        var id = UUID()
        /// CGEvent button number: 2 = middle, 3 = back, 4 = forward, …
        var button: Int?
        var modifiers: Modifiers
        /// An action string: "key cmd+left_bracket", "none", or anything from the config.
        var action: String
        /// Modifiers as written in the file when they do not parse: written back as they were,
        /// not dropped (which would make the rule fire without them), until the button is recorded again.
        var invalidModifiers: String?

        var isComplete: Bool { button != nil && !action.isEmpty }

        /// What the rule is, to keep its id across reloads.
        var key: [String] { [button.map(String.init) ?? "", String(modifiers.rawValue), invalidModifiers ?? "", action] }

        /// Whether `other` fires on the same click: same button, same modifiers (or the same
        /// unparsed text, which the config rejects alike).
        func sameTrigger(as other: Rule) -> Bool {
            button == other.button && modifiers == other.modifiers && invalidModifiers == other.invalidModifiers
        }
    }

    enum Field: Equatable {
        case button(UUID)
        case action(UUID)

        var ruleID: UUID {
            switch self {
            case .button(let id), .action(let id): return id
            }
        }
    }

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var reverseScroll = TapConfig.defaultReverseScroll
    /// The cap being recorded: its own object, so starting or ending a capture redraws the
    /// rows, not the page.
    let capture: FieldCapture<Field>

    /// What the page writes, as loaded: each part is written only once it differs.
    struct Snapshot {
        var reverseScroll: Bool
        /// The complete mappings, in the file's form.
        var buttons: [[String: Any]]
    }

    var sync = FileSync<Snapshot>(SyncedSlice(sections: "mouse"))

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(eventTap: EventTap, config: [String: Any]) {
        capture = FieldCapture(recorder: ShortcutRecorder(eventTap: eventTap))
        // A capture that ends with nothing recorded: a mapping left incomplete goes (it was
        // never saved), except the one whose action is recorded next.
        capture.onEnd = { [weak self] next in
            guard let self else { return }
            rules.removeAll { !$0.isComplete && $0.id != next?.ruleID }
            applyDeferredReload()
        }
        load(config)
    }

    // MARK: - Editing

    /// A new mapping records its button, then its action.
    func addRule() {
        let rule = Rule(button: nil, modifiers: [], action: "")
        rules.append(rule)
        startCapture(.button(rule.id))
    }

    func remove(_ id: UUID) {
        if capturing?.ruleID == id { capture.end() }
        edit { rules.removeAll { $0.id == id } }
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
                if let combo = keyCombo(of: item.action) {
                    byCombo.append((combo, item.name))
                }
            }
        }
        return (byAction, byCombo)
    }()

    /// The shortcut a "key …" action sends, as written.
    static func keys(of action: String) -> String? {
        action.hasPrefix("key ") ? String(action.dropFirst(4)) : nil
    }

    /// The shortcut a "key …" action sends, parsed.
    static func keyCombo(of action: String) -> KeyCombo? {
        keys(of: action).flatMap { try? KeyCombo.parse($0) }
    }

    /// The preset name for an action, matching key shortcuts by meaning ("cmd+[" == "cmd+left_bracket").
    private static func presetName(_ action: String) -> String? {
        if let name = presetNames.byAction[action] { return name }
        guard let combo = keyCombo(of: action) else { return nil }
        return presetNames.byCombo.first { $0.combo == combo }?.name
    }

    func setReverseScroll(_ on: Bool) {
        guard reverseScroll != on else { return }
        edit { reverseScroll = on }
    }

    func warning(for rule: Rule) -> String? {
        Self.isDuplicate(rule, in: rules) ? "Another mapping uses the same button and modifiers" : nil
    }

    /// Whether another complete rule fires on the same click as `rule`.
    static func isDuplicate(_ rule: Rule, in rules: [Rule]) -> Bool {
        rule.isComplete && rules.contains { $0.id != rule.id && $0.isComplete && $0.sameTrigger(as: rule) }
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
        if let keys = keys(of: action) { return RemapTarget.label(keys) }
        return action
    }

    // MARK: - Capture

    /// Button: click it over the settings window (hold modifiers to include them);
    /// mappings are suspended meanwhile so the button reaches the window.
    /// Action: press the keys it should send, e.g. ⌘ and [ together.
    func startCapture(_ field: Field) {
        capture.begin(field)
        switch field {
        case .button:
            capture.recorder.start(.otherMouseDown, pausing: .buttons) { [weak self] event in
                guard let self, event.buttonNumber >= 2, event.buttonNumber < 32 else { return false }
                let modifiers = Modifiers(event.modifierFlags)
                finishCapture { $0.button = event.buttonNumber; $0.modifiers = modifiers; $0.invalidModifiers = nil }
                return true
            }
        case .action:
            // As on the Shortcuts page, Escape alone cancels and Delete alone clears (the
            // button then does nothing).
            capture.recorder.startShortcut { [weak self] input in
                switch input {
                case .cancel: self?.stopCapture()
                case .clear: self?.finishCapture { $0.action = "none" }
                case .keys(let keys): self?.finishCapture { $0.action = "key \(keys)" }
                }
            }
        }
    }

    /// The recorded button or keys go into the rule being recorded.
    private func finishCapture(_ change: (inout Rule) -> Void) {
        guard let field = capturing else { return }
        capture.end()
        edit { rules.update(id: field.ruleID, change) }
        // A new mapping goes straight on to its action.
        if case .button(let id) = field, rules.first(where: { $0.id == id })?.action.isEmpty == true {
            startCapture(.action(id))
        }
    }

    /// An action picked from the menu: it ends the recording of that action.
    func setAction(_ action: String, for id: UUID) {
        if capturing == .action(id) { capture.end() }
        edit { rules.update(id: id) { $0.action = action } }
    }

    // MARK: - Persistence

    func load(_ config: [String: Any]) {
        let mouse = ConfigWriter.section("mouse", of: config)
        let reverse = mouse["reverseScroll"] as? Bool ?? TapConfig.defaultReverseScroll
        assignIfChanged(reverse, to: &reverseScroll)
        // In the order of the file: when two rules share a button, the last one wins.
        var loaded = (mouse["buttons"] as? [[String: Any]] ?? []).map {
            let text = $0["modifiers"] as? String ?? ""
            let modifiers = try? Modifiers.parse(text)
            return Rule(button: $0["button"] as? Int, modifiers: modifiers ?? [],
                        action: $0["action"] as? String ?? "", invalidModifiers: modifiers == nil ? text : nil)
        }
        let ids = reusedIDs(for: loaded.map(\.key), from: rules.map { ($0.key, $0.id) })
        for index in loaded.indices { loaded[index].id = ids[index] }
        // A mapping being recorded is not in the file yet: it stays.
        assignIfChanged(loaded + rules.filter { !$0.isComplete && !ids.contains($0.id) }, to: &rules)
        sync.didLoad(config, snapshot)
    }

    private var snapshot: Snapshot {
        Snapshot(reverseScroll: reverseScroll, buttons: rules.filter(\.isComplete).map { rule in
            var entry: [String: Any] = ["button": rule.button ?? 0, "action": rule.action]
            if let invalid = rule.invalidModifiers {
                entry["modifiers"] = invalid
            } else if !rule.modifiers.isEmpty {
                entry["modifiers"] = rule.modifiers.configText
            }
            return entry
        })
    }

    /// Writes what changed since the load: the scroll setting (left out until changed, like
    /// every option the user never set) and the mappings.
    func save() {
        let current = snapshot
        let old = sync.loaded
        sync.save(current) { root in
            ConfigWriter.amend(&root, section: "mouse") { mouse in
                mouse.write("reverseScroll", current.reverseScroll, since: old?.reverseScroll)
                mouse.writeList("buttons", current.buttons, since: old?.buttons)
            }
        }
    }
}

extension MouseModel: CaptureModel {}
