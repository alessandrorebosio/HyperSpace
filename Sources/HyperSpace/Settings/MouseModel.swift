import AppKit

/// State of the mouse settings. Every change is written to config.json at once;
/// the config watcher then applies it to the event tap.
final class MouseModel: ObservableObject {
    struct Rule: Identifiable, Equatable {
        let id = UUID()
        /// CGEvent button number: 2 = middle, 3 = back, 4 = forward, …
        var button: Int?
        var modifiers: Modifiers
        /// An action string: "key cmd+left_bracket", "none", or anything from the config.
        var action: String

        var isComplete: Bool { button != nil && !action.isEmpty }
    }

    enum Field: Equatable {
        case button(UUID)
        case action(UUID)
    }

    @Published var rules: [Rule] = []
    @Published private(set) var reverseScroll = false
    @Published private(set) var capturing: Field?
    @Published private(set) var saveError: String?

    private let eventTap: EventTap
    private var monitor: Any?

    init(eventTap: EventTap) {
        self.eventTap = eventTap
        load()
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

    func disable(_ id: UUID) {
        setAction("none", for: id)
    }

    func choose(_ action: String, for id: UUID) {
        setAction(action, for: id)
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
        ]),
    ]

    /// The preset name for an action, matching key shortcuts by meaning ("cmd+[" == "cmd+left_bracket").
    private static func presetName(_ action: String) -> String? {
        let combo = action.hasPrefix("key ") ? try? KeyCombo.parse(String(action.dropFirst(4))) : nil
        for (_, items) in presets {
            for item in items {
                if item.action == action { return item.name }
                if let combo, item.action.hasPrefix("key "),
                   (try? KeyCombo.parse(String(item.action.dropFirst(4)))) == combo { return item.name }
            }
        }
        return nil
    }

    func setReverseScroll(_ on: Bool) {
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, event.buttonNumber >= 2, event.buttonNumber < 32 else { return event }
                let modifiers = Modifiers(event.modifierFlags)
                update(field) { $0.button = event.buttonNumber; $0.modifiers = modifiers }
                return nil
            }
        case .action:
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let name = KeyCodes.name(forKeyCode: event.keyCode) else {
                    NSSound.beep()
                    return nil
                }
                let modifiers = Modifiers(event.modifierFlags)
                let combo = modifiers.isEmpty ? name : RemapTarget.text(modifiers, key: name)
                update(field) { $0.action = "key \(combo)" }
                return nil
            }
        }
    }

    func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if case .button = capturing { eventTap.setButtonsSuspended(false) }
        capturing = nil
    }

    private func update(_ field: Field, _ change: (inout Rule) -> Void) {
        let id: UUID
        switch field {
        case .button(let ruleID), .action(let ruleID): id = ruleID
        }
        if let index = rules.firstIndex(where: { $0.id == id }) { change(&rules[index]) }
        stopCapture()
        save()
        // A new mapping goes straight on to its action.
        if case .button = field, let rule = rules.first(where: { $0.id == id }), rule.action.isEmpty {
            startCapture(.action(id))
        }
    }

    private func setAction(_ action: String, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        if capturing == .action(id) { stopCapture() }
        rules[index].action = action
        save()
    }

    // MARK: - Persistence

    private func load() {
        let mouse = ConfigWriter.read()["mouse"] as? [String: Any]
        reverseScroll = mouse?["reverseScroll"] as? Bool ?? false
        rules = (mouse?["buttons"] as? [[String: Any]] ?? []).map {
            Rule(button: $0["button"] as? Int,
                 modifiers: (try? Modifiers.parse($0["modifiers"] as? String ?? "")) ?? [],
                 action: $0["action"] as? String ?? "")
        }
        .sorted { ($0.button ?? .max, $0.modifiers.rawValue) < ($1.button ?? .max, $1.modifiers.rawValue) }
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        do {
            try ConfigWriter.update { root in
                var mouse = root["mouse"] as? [String: Any] ?? [:]
                mouse["reverseScroll"] = reverseScroll
                mouse["buttons"] = complete.map { rule -> [String: Any] in
                    var entry: [String: Any] = ["button": rule.button!, "action": rule.action]
                    if !rule.modifiers.isEmpty { entry["modifiers"] = rule.modifiers.configText }
                    return entry
                }
                root["mouse"] = mouse
            }
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
