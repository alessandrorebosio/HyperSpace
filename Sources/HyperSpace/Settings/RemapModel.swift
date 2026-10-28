import AppKit

/// State of the remap editor. Every change is written to config.json at once;
/// the config watcher then applies it to the keyboards.
final class RemapModel: ObservableObject {
    struct Rule: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var to: String
        /// "all", "builtin", "external" or a product name.
        var keyboard: String

        var isComplete: Bool { !from.isEmpty && !to.isEmpty }
    }

    enum Field: Equatable {
        case hyper
        case from(UUID)
        case to(UUID)
    }

    @Published var rules: [Rule] = []
    @Published var hyperKey = ""
    @Published private(set) var keyboards: [KeyboardRemapper.Keyboard] = []
    @Published private(set) var capturing: Field?
    @Published private(set) var saveError: String?

    private let remapper: KeyboardRemapper
    private var monitor: Any?

    init(remapper: KeyboardRemapper) {
        self.remapper = remapper
        load()
        refreshKeyboards()
        remapper.onKeyboardsChanged = { [weak self] in self?.refreshKeyboards() }
    }

    deinit {
        stopCapture()
    }

    // MARK: - Editing

    func addRule() {
        let rule = Rule(from: "", to: "", keyboard: "all")
        rules.append(rule)
        startCapture(.from(rule.id))
    }

    func remove(_ id: UUID) {
        if capturing == .from(id) || capturing == .to(id) { stopCapture() }
        rules.removeAll { $0.id == id }
        save()
    }

    func setTarget(_ name: String, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].to = name
        save()
    }

    func setKeyboard(_ keyboard: String, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].keyboard = keyboard
        save()
    }

    func clearHyperKey() {
        hyperKey = ""
        save()
    }

    /// Keyboard choices for a rule: the generic targets, every connected keyboard,
    /// and the rule's own target even if that keyboard is unplugged right now.
    func keyboardOptions(for rule: Rule) -> [String] {
        var options = ["all", "builtin", "external"] + keyboards.filter { !$0.builtIn }.map(\.product)
        if !options.contains(rule.keyboard) { options.append(rule.keyboard) }
        return options
    }

    func keyboardLabel(_ option: String) -> String {
        switch option {
        case "all": return "All keyboards"
        case "builtin": return "Built-in"
        case "external": return "All external"
        default: return option
        }
    }

    /// Explains why a rule will not do what it seems to, if anything.
    func warning(for rule: Rule) -> String? {
        guard rule.isComplete else { return nil }
        let duplicate = rules.contains { $0.id != rule.id && $0.isComplete && $0.from == rule.from && $0.keyboard == rule.keyboard }
        if duplicate { return "Another remap uses the same key on the same keyboards" }
        if rule.from == hyperKey { return "This key is also the hyper key; this remap wins where it applies" }
        return nil
    }

    // MARK: - Key capture

    /// Listens for the next key press. Remapping is suspended meanwhile so the
    /// physical key is captured, not what it is currently mapped to.
    func startCapture(_ field: Field) {
        stopCapture()
        capturing = field
        remapper.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged && !Self.isPress(event) { return nil }
            if let name = KeyCodes.name(forKeyCode: event.keyCode) {
                finishCapture(name)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard capturing != nil else { return }
        capturing = nil
        remapper.resume()
    }

    private func finishCapture(_ name: String) {
        switch capturing {
        case .hyper:
            hyperKey = name
        case .from(let id):
            if let index = rules.firstIndex(where: { $0.id == id }) { rules[index].from = name }
        case .to(let id):
            if let index = rules.firstIndex(where: { $0.id == id }) { rules[index].to = name }
        case nil:
            break
        }
        stopCapture()
        save()
    }

    /// Modifier keys send flagsChanged on press and on release; keep the press.
    private static func isPress(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 0x37, 0x36: return flags.contains(.command)
        case 0x38, 0x3C: return flags.contains(.shift)
        case 0x3A, 0x3D: return flags.contains(.option)
        case 0x3B, 0x3E: return flags.contains(.control)
        case 0x3F: return flags.contains(.function)
        default: return true // caps lock sends one event per press
        }
    }

    // MARK: - Persistence

    private func load() {
        let keyboard = ConfigWriter.read()["keyboard"] as? [String: Any]
        hyperKey = keyboard?["hyperKey"] as? String ?? ""
        rules = (keyboard?["remap"] as? [[String: Any]] ?? []).map {
            Rule(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", keyboard: $0["keyboard"] as? String ?? "all")
        }
    }

    private func refreshKeyboards() {
        keyboards = remapper.connectedKeyboards()
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        do {
            try ConfigWriter.update { root in
                var keyboard = root["keyboard"] as? [String: Any] ?? [:]
                keyboard["hyperKey"] = hyperKey.isEmpty ? nil : hyperKey
                keyboard["remap"] = complete.map { rule -> [String: Any] in
                    var entry: [String: Any] = ["from": rule.from, "to": rule.to]
                    if rule.keyboard != "all" { entry["keyboard"] = rule.keyboard }
                    return entry
                }
                root["keyboard"] = keyboard
            }
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
