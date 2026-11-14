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
    @Published private(set) var capturing: Field?

    private let recorder: ShortcutRecorder
    /// The section, and the scroll setting as loaded: written only once it changes.
    private var sync = FileSync<Bool>(SyncedSlice(sections: "mouse"))
    var saveStatus: SaveStatus { sync.status }

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(eventTap: EventTap, config: [String: Any]) {
        recorder = ShortcutRecorder(eventTap: eventTap)
        load(config)
    }

    func reload(from root: [String: Any]) {
        if sync.shouldReload(root, editing: capturing != nil) { load(root) }
    }

    // MARK: - Editing

    /// A new mapping records its button, then its action.
    func addRule() {
        let rule = Rule(button: nil, modifiers: [], action: "")
        rules.append(rule)
        startCapture(.button(rule.id))
    }

    func remove(_ id: UUID) {
        if capturing?.ruleID == id { endCapture() }
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
        stopCapture(keeping: field.ruleID)
        capturing = field
        switch field {
        case .button:
            recorder.start(.otherMouseDown, pausing: .buttons) { [weak self] event in
                guard let self, event.buttonNumber >= 2, event.buttonNumber < 32 else { return false }
                let modifiers = Modifiers(event.modifierFlags)
                finishCapture { $0.button = event.buttonNumber; $0.modifiers = modifiers; $0.invalidModifiers = nil }
                return true
            }
        case .action:
            // As on the Shortcuts page, Escape alone cancels and Delete alone clears (the
            // button then does nothing).
            recorder.startShortcut { [weak self] input in
                switch input {
                case .cancel: self?.stopCapture()
                case .clear: self?.finishCapture { $0.action = "none" }
                case .keys(let keys): self?.finishCapture { $0.action = "key \(keys)" }
                }
            }
        }
    }

    /// Recording ends with nothing recorded (Esc, the cap clicked again, another page, the
    /// window closed). As on every page, a mapping left incomplete goes: it was never saved.
    func stopCapture() {
        stopCapture(keeping: nil)
    }

    /// `stopCapture`, keeping the rule `kept` even if incomplete (its action is next).
    private func stopCapture(keeping kept: UUID?) {
        guard endCapture() else { return }
        rules.removeAll { !$0.isComplete && $0.id != kept }
        if let root = sync.takeDeferredReload() { load(root) }
    }

    /// Stops listening; false when nothing was being recorded.
    @discardableResult
    private func endCapture() -> Bool {
        recorder.stop()
        guard capturing != nil else { return false }
        capturing = nil
        return true
    }

    /// The recorded button or keys go into the rule being recorded.
    private func finishCapture(_ change: (inout Rule) -> Void) {
        guard let field = capturing else { return }
        endCapture()
        edit { rules.update(id: field.ruleID, change) }
        // A new mapping goes straight on to its action.
        if case .button(let id) = field, rules.first(where: { $0.id == id })?.action.isEmpty == true {
            startCapture(.action(id))
        }
    }

    /// An action picked from the menu: it ends the recording of that action.
    func setAction(_ action: String, for id: UUID) {
        if capturing == .action(id) { endCapture() }
        edit { rules.update(id: id) { $0.action = action } }
    }

    // MARK: - Persistence

    private func load(_ config: [String: Any]) {
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
        sync.didLoad(config, reverse)
    }

    /// A change made here: a reload skipped while recording comes first, so the save that
    /// follows writes the file's latest mappings with the change.
    private func edit(_ change: () -> Void) {
        if let root = sync.takeDeferredReload() { load(root) }
        change()
        save()
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        let loadedScroll = sync.loaded
        let reverseScroll = reverseScroll
        sync.save(reverseScroll) { root in
            ConfigWriter.edit(&root, section: "mouse") { mouse in
                // Left out until changed, like every option the user never set.
                if reverseScroll != loadedScroll { mouse["reverseScroll"] = reverseScroll }
                let buttons = complete.map { rule -> [String: Any] in
                    var entry: [String: Any] = ["button": rule.button!, "action": rule.action]
                    if let invalid = rule.invalidModifiers {
                        entry["modifiers"] = invalid
                    } else if !rule.modifiers.isEmpty {
                        entry["modifiers"] = rule.modifiers.configText
                    }
                    return entry
                }
                // An empty list is left out, like every list the pages write.
                mouse["buttons"] = buttons.isEmpty ? nil : buttons
            }
        }
    }
}

extension MouseModel: CaptureModel {}
