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
        case from(UUID)
        case to(UUID)
    }

    @Published var rules: [Rule] = []
    @Published private(set) var keyboards: [KeyboardRemapper.Keyboard] = []
    @Published private(set) var capturing: Field?
    @Published private(set) var saveError: String?
    /// Modifiers held so far while capturing a target, shown live ("⌃⌥⇧…").
    @Published private(set) var capturePreview = ""
    @Published private(set) var isKeyboardLocked = false
    /// "2:41" until the lock lifts by itself, refreshed every second while locked.
    @Published private(set) var unlocksIn: String?
    @Published var lockMinutes = KeyboardLock.minutes {
        didSet { KeyboardLock.minutes = lockMinutes }
    }
    private var countdown: Timer?

    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private var lockObserver: NSObjectProtocol?
    private let monitor = LocalEventMonitor()
    // Target capture: the most modifiers held at once, and the physical key when only one was pressed.
    private var peakModifiers: Modifiers = []
    private var modifierPresses = 0
    private var soleModifierKey: UInt16?

    init(remapper: KeyboardRemapper, eventTap: EventTap) {
        self.remapper = remapper
        self.eventTap = eventTap
        // Also locked and unlocked from the menu bar, and unlocked by the timer.
        lockObserver = NotificationCenter.default.addObserver(
            forName: EventTap.keyboardLockDidChange, object: eventTap, queue: .main
        ) { [weak self] _ in self?.syncLock() }
        syncLock()
        load()
        refreshKeyboards()
        remapper.onKeyboardsChanged = { [weak self] in self?.refreshKeyboards() }
    }

    deinit {
        stopCapture()
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
        countdown?.invalidate()
    }

    private func syncLock() {
        isKeyboardLocked = eventTap.isKeyboardLocked
        countdown?.invalidate()
        countdown = nil
        guard let until = eventTap.keyboardUnlocksAt else {
            unlocksIn = nil
            return
        }
        unlocksIn = KeyboardLock.remaining(until: until)
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.unlocksIn = KeyboardLock.remaining(until: until)
        }
    }

    /// Ignores every key until unlocked with the mouse (to clean the keyboard).
    func setKeyboardLocked(_ locked: Bool) {
        if locked { stopCapture() }
        eventTap.setKeyboardLocked(locked)
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
        return duplicate ? "Another remap uses the same key on the same keyboards" : nil
    }

    // MARK: - Key capture

    /// Listens for keys. Remapping is suspended meanwhile so the physical keys are
    /// captured, not what they are currently mapped to.
    ///
    /// - Source: the first key pressed.
    /// - Target: what you press, as a whole: a key, modifiers + a key (⌘ Space), or
    ///   modifiers alone (hold ⇧⌃⌥, release → ⌃⌥⇧). A single modifier released on its
    ///   own is that physical key (e.g. Right Option).
    func startCapture(_ field: Field) {
        stopCapture()
        capturing = field
        peakModifiers = []
        modifierPresses = 0
        soleModifierKey = nil
        capturePreview = ""
        remapper.suspend()
        monitor.start([.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return false }
            if case .to = capturing {
                captureTarget(event)
            } else {
                captureSource(event)
            }
            return true
        }
    }

    private func captureSource(_ event: NSEvent) {
        if event.type == .flagsChanged && !Self.isPress(event) { return }
        guard let name = KeyCodes.name(forKeyCode: event.keyCode) else { return NSSound.beep() }
        finishCapture(name)
    }

    private func captureTarget(_ event: NSEvent) {
        guard let name = KeyCodes.name(forKeyCode: event.keyCode) else { return NSSound.beep() }
        let held = Modifiers(event.modifierFlags)

        if event.type == .keyDown {
            finishCapture(held.text(key: name))
            return
        }
        // Caps lock and fn are plain keys here, not part of a combination.
        guard Modifiers.modifierKey(name) != nil else { return finishCapture(name) }

        if Self.isPress(event) {
            modifierPresses += 1
            soleModifierKey = modifierPresses == 1 ? event.keyCode : nil
            peakModifiers.formUnion(held)
            capturePreview = peakModifiers.symbols
            return
        }
        guard held.isEmpty, !peakModifiers.isEmpty else { return }
        if let sole = soleModifierKey, let single = KeyCodes.name(forKeyCode: sole) {
            finishCapture(single)
        } else {
            finishCapture(peakModifiers.text(key: nil))
        }
    }

    func stopCapture() {
        monitor.stop()
        guard capturing != nil else { return }
        capturing = nil
        capturePreview = ""
        remapper.resume()
    }

    private func finishCapture(_ name: String) {
        switch capturing {
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
        rules = (keyboard?["remap"] as? [[String: Any]] ?? []).map {
            Rule(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", keyboard: $0["keyboard"] as? String ?? "all")
        }
        // The editor shows the hyper key as an ordinary remap to "hyper"; it is saved that way too.
        if let hyper = keyboard?["hyperKey"] as? String, !hyper.isEmpty {
            rules.insert(Rule(from: hyper, to: "hyper", keyboard: "all"), at: 0)
        }
    }

    private func refreshKeyboards() {
        keyboards = remapper.connectedKeyboards()
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        saveError = ConfigWriter.save { root in
            var keyboard = root["keyboard"] as? [String: Any] ?? [:]
            keyboard["hyperKey"] = nil
            keyboard["remap"] = complete.map { rule -> [String: Any] in
                var entry: [String: Any] = ["from": rule.from, "to": rule.to]
                if rule.keyboard != "all" { entry["keyboard"] = rule.keyboard }
                return entry
            }
            root["keyboard"] = keyboard
        }
    }
}
