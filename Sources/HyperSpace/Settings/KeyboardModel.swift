import AppKit
import Combine

/// State of the Keyboard page: the key remaps and the keyboard lock. Every remap change is
/// written to config.json at once; the config watcher then applies it to the keyboards.
final class KeyboardModel: ObservableObject, FileBackedModel {
    struct Rule: Identifiable, Equatable {
        var id = UUID()
        var from: String
        var to: String
        /// `KeyboardTarget.allText`, `.builtInText`, `.externalText` or a product name.
        var keyboard: String

        var isComplete: Bool { !from.isEmpty && !to.isEmpty }

        /// What the rule is, to keep its id across reloads.
        var key: [String] { [from, to, keyboard] }
    }

    enum Field: Equatable {
        case from(UUID)
        case to(UUID)

        var ruleID: UUID {
            switch self {
            case .from(let id), .to(let id): return id
            }
        }
    }

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var keyboards: [KeyboardRemapper.Keyboard] = []
    @Published private(set) var capturing: Field?
    /// Modifiers held so far while capturing a target, shown live ("⌃⌥⇧…").
    @Published private(set) var capturePreview = ""
    @Published private(set) var isKeyboardLocked = false
    /// "2:41" until the lock lifts by itself: its own object, so the tick every second redraws
    /// the lock row only, not every remap.
    let unlockCountdown = UnlockCountdown()
    @Published private(set) var lockMinutes = KeyboardLock.minutes

    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private var lockObserver: NSObjectProtocol?
    private let recorder: ShortcutRecorder
    /// The remaps and the hyper key; the bindings belong to the Shortcuts page.
    private var sync = FileSync<Void>(SyncedSlice { root in
        ConfigWriter.section("keyboard", of: root).filter { $0.key != "bindings" }
    })
    var saveStatus: SaveStatus { sync.status }
    // Target capture: the most modifiers held at once, and the physical key when only one was pressed.
    private var peakModifiers: Modifiers = []
    private var modifierPresses = 0
    private var soleModifierKey: UInt16?

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(remapper: KeyboardRemapper, eventTap: EventTap, config: [String: Any]) {
        self.remapper = remapper
        self.eventTap = eventTap
        recorder = ShortcutRecorder(eventTap: eventTap, remapper: remapper)
        // Also locked and unlocked from the menu bar, and unlocked by the timer.
        lockObserver = NotificationCenter.default.addObserver(
            forName: EventTap.keyboardLockDidChange, object: eventTap, queue: .main
        ) { [weak self] _ in self?.syncLock() }
        syncLock()
        load(config)
        refreshKeyboards()
        remapper.onKeyboardsChanged = { [weak self] in self?.refreshKeyboards() }
    }

    /// The window closes: nothing stays suspended or observed.
    func close() {
        stopCapture()
        remapper.onKeyboardsChanged = nil
    }

    deinit {
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    func reload(from root: [String: Any]) {
        if sync.shouldReload(root, editing: capturing != nil) { load(root) }
    }

    func setLockMinutes(_ minutes: Int) {
        guard minutes != lockMinutes else { return }
        lockMinutes = minutes
        KeyboardLock.minutes = minutes
    }

    private func syncLock() {
        assignIfChanged(eventTap.isKeyboardLocked, to: &isKeyboardLocked)
        unlockCountdown.run(until: eventTap.keyboardUnlocksAt)
    }

    /// Ignores every key until unlocked with the mouse (to clean the keyboard).
    func setKeyboardLocked(_ locked: Bool) {
        if locked { stopCapture() }
        eventTap.setKeyboardLocked(locked)
    }

    // MARK: - Editing

    /// A new rule records its key, then what it becomes.
    func addRule() {
        let rule = Rule(from: "", to: "", keyboard: KeyboardTarget.allText)
        rules.append(rule)
        startCapture(.from(rule.id))
    }

    func remove(_ id: UUID) {
        if capturing?.ruleID == id { endCapture() }
        edit { rules.removeAll { $0.id == id } }
    }

    /// A target picked from the menu: it ends the recording of that target.
    func setTarget(_ name: String, for id: UUID) {
        if capturing == .to(id) { endCapture() }
        edit { rules.update(id: id) { $0.to = name } }
    }

    func setKeyboard(_ keyboard: String, for id: UUID) {
        edit { rules.update(id: id) { $0.keyboard = keyboard } }
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
    ///
    /// Every key is recorded, Esc too (it can be remapped): clicking the cap again cancels.
    func startCapture(_ field: Field) {
        stopCapture(keeping: field.ruleID)
        capturing = field
        peakModifiers = []
        modifierPresses = 0
        soleModifierKey = nil
        capturePreview = ""
        // A bound shortcut is recorded, not run.
        recorder.start([.keyDown, .flagsChanged], pausing: [.remaps, .keyBindings]) { [weak self] event in
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

    /// Recording ends with nothing recorded (the cap clicked again, another page, the window
    /// closed). As on every page, a rule left incomplete goes: it was never saved.
    func stopCapture() {
        stopCapture(keeping: nil)
    }

    /// `stopCapture`, keeping the rule `kept` even if incomplete (its other key is next).
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
        capturePreview = ""
        return true
    }

    private func finishCapture(_ name: String) {
        guard let field = capturing else { return }
        endCapture()
        edit {
            switch field {
            case .from(let id): rules.update(id: id) { $0.from = name }
            case .to(let id): rules.update(id: id) { $0.to = name }
            }
        }
        // A new rule goes straight on to what its key becomes.
        if case .from(let id) = field, rules.first(where: { $0.id == id })?.to.isEmpty == true {
            startCapture(.to(id))
        }
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
        var loaded = RawConfig.Remap.withHyperKey(remaps, hyperKey: keyboard["hyperKey"] as? String).map {
            Rule(from: $0.from, to: $0.to, keyboard: $0.keyboard ?? KeyboardTarget.allText)
        }
        let ids = reusedIDs(for: loaded.map(\.key), from: rules.map { ($0.key, $0.id) })
        for index in loaded.indices { loaded[index].id = ids[index] }
        // A rule being recorded is not in the file yet: it stays.
        assignIfChanged(loaded + rules.filter { !$0.isComplete && !ids.contains($0.id) }, to: &rules)
        sync.didLoad(config)
    }

    private func refreshKeyboards() {
        assignIfChanged(remapper.connectedKeyboards(), to: &keyboards)
    }

    /// A change made here: a reload skipped while recording comes first, so the save that
    /// follows writes the file's latest remaps with the change.
    private func edit(_ change: () -> Void) {
        if let root = sync.takeDeferredReload() { load(root) }
        change()
        save()
    }

    private func save() {
        let complete = rules.filter(\.isComplete)
        sync.save { root in
            ConfigWriter.edit(&root, section: "keyboard") { keyboard in
                keyboard["hyperKey"] = nil
                let remaps = complete.map { rule -> [String: Any] in
                    var entry: [String: Any] = ["from": rule.from, "to": rule.to]
                    if rule.keyboard != KeyboardTarget.allText { entry["keyboard"] = rule.keyboard }
                    return entry
                }
                // An empty list is left out, like every list the pages write.
                keyboard["remap"] = remaps.isEmpty ? nil : remaps
            }
        }
    }
}

extension KeyboardModel: CaptureModel {}

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
