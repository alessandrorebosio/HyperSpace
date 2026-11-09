import AppKit
import Combine

/// State of the remap editor. Every change is written to config.json at once;
/// the config watcher then applies it to the keyboards.
final class KeyboardModel: ObservableObject {
    struct Rule: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var to: String
        /// `KeyboardTarget.allText`, `.builtInText`, `.externalText` or a product name.
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
    /// "2:41" until the lock lifts by itself: its own object, so the tick every second redraws
    /// the lock row only, not every remap.
    let unlockCountdown = UnlockCountdown()
    @Published var lockMinutes = KeyboardLock.minutes {
        didSet { KeyboardLock.minutes = lockMinutes }
    }

    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private var lockObserver: NSObjectProtocol?
    private let monitor = LocalEventMonitor()
    // Target capture: the most modifiers held at once, and the physical key when only one was pressed.
    private var peakModifiers: Modifiers = []
    private var modifierPresses = 0
    private var soleModifierKey: UInt16?

    /// `config`: the file as `ConfigWriter.read()` returns it.
    init(remapper: KeyboardRemapper, eventTap: EventTap, config: [String: Any]) {
        self.remapper = remapper
        self.eventTap = eventTap
        // Also locked and unlocked from the menu bar, and unlocked by the timer.
        lockObserver = NotificationCenter.default.addObserver(
            forName: EventTap.keyboardLockDidChange, object: eventTap, queue: .main
        ) { [weak self] _ in self?.syncLock() }
        syncLock()
        load(config)
        refreshKeyboards()
        remapper.onKeyboardsChanged = { [weak self] in self?.refreshKeyboards() }
    }

    deinit {
        stopCapture()
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    private func syncLock() {
        // A `@Published` assignment redraws the page even when the value is the same.
        if isKeyboardLocked != eventTap.isKeyboardLocked { isKeyboardLocked = eventTap.isKeyboardLocked }
        unlockCountdown.run(until: eventTap.keyboardUnlocksAt)
    }

    /// Ignores every key until unlocked with the mouse (to clean the keyboard).
    func setKeyboardLocked(_ locked: Bool) {
        if locked { stopCapture() }
        eventTap.setKeyboardLocked(locked)
    }

    // MARK: - Editing

    func addRule() {
        let rule = Rule(from: "", to: "", keyboard: KeyboardTarget.allText)
        rules.append(rule)
        startCapture(.from(rule.id))
    }

    func remove(_ id: UUID) {
        if capturing == .from(id) || capturing == .to(id) { stopCapture() }
        rules.removeAll { $0.id == id }
        save()
    }

    func setTarget(_ name: String, for id: UUID) {
        if rules.update(id: id, { $0.to = name }) { save() }
    }

    func setKeyboard(_ keyboard: String, for id: UUID) {
        if rules.update(id: id, { $0.keyboard = keyboard }) { save() }
    }

    /// Keyboard choices for a rule: the generic targets, every connected keyboard,
    /// and the rule's own target even if that keyboard is unplugged right now.
    func keyboardOptions(for rule: Rule) -> [String] {
        var options = [KeyboardTarget.allText, KeyboardTarget.builtInText, KeyboardTarget.externalText] + keyboards.filter { !$0.builtIn }.map(\.product)
        if !options.contains(rule.keyboard) { options.append(rule.keyboard) }
        return options
    }

    static func keyboardLabel(_ option: String) -> String {
        switch option {
        case KeyboardTarget.allText: return "All keyboards"
        case KeyboardTarget.builtInText: return "Built-in"
        case KeyboardTarget.externalText: return "All external"
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
            rules.update(id: id) { $0.from = name }
        case .to(let id):
            rules.update(id: id) { $0.to = name }
        case nil:
            break
        }
        stopCapture()
        save()
    }

    /// Modifier keys send flagsChanged on press and on release; keep the press.
    private static func isPress(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard let name = KeyCodes.name(forKeyCode: event.keyCode) else { return true }
        if name == "fn" { return flags.contains(.function) }
        if let modifier = Modifiers.modifierKey(name) { return Modifiers(flags).contains(modifier) }
        return true // caps lock sends one event per press
    }

    // MARK: - Persistence

    private func load(_ config: [String: Any]) {
        let keyboard = ConfigWriter.section("keyboard", of: config)
        let remaps = (keyboard["remap"] as? [[String: Any]] ?? []).map {
            RawConfig.Remap(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", keyboard: $0["keyboard"] as? String)
        }
        // The editor shows the hyper key as an ordinary remap to "hyper"; it is saved that way too.
        rules = RawConfig.Remap.withHyperKey(remaps, hyperKey: keyboard["hyperKey"] as? String).map {
            Rule(from: $0.from, to: $0.to, keyboard: $0.keyboard ?? KeyboardTarget.allText)
        }
    }

    private func refreshKeyboards() {
        keyboards = remapper.connectedKeyboards()
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        saveError = ConfigWriter.save(section: "keyboard") { keyboard in
            keyboard["hyperKey"] = nil
            keyboard["remap"] = complete.map { rule -> [String: Any] in
                var entry: [String: Any] = ["from": rule.from, "to": rule.to]
                if rule.keyboard != KeyboardTarget.allText { entry["keyboard"] = rule.keyboard }
                return entry
            }
        }
    }
}

/// The time left until a locked keyboard unlocks by itself ("2:41"), refreshed every second.
final class UnlockCountdown: ObservableObject {
    @Published private(set) var text: String?
    private var timer: Timer?

    /// Counts down to `date`; nil stops.
    func run(until date: Date?) {
        timer?.invalidate()
        timer = nil
        guard let date else {
            if text != nil { text = nil }
            return
        }
        text = KeyboardLock.remaining(until: date)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.text = KeyboardLock.remaining(until: date)
        }
    }

    deinit {
        timer?.invalidate()
    }
}
