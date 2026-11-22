import AppKit
import Combine

/// An NSEvent local monitor for key or button capture. The handler returns true when
/// it consumed the event; the monitor is removed on `stop` or when released.
final class LocalEventMonitor {
    private var token: Any?

    func start(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { handler($0) ? nil : $0 }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { stop() }
}

/// What a key press means while a shortcut is being recorded.
enum ShortcutInput: Equatable {
    /// The keys pressed, as the config writes them ("cmd+shift+k").
    case keys(String)
    /// Delete alone: the shortcut is cleared.
    case clear
    /// Escape alone: nothing is recorded.
    case cancel
}

/// The capture shared by the Keyboard, Mouse and window pages: a local event monitor, with
/// what would get in its way (key bindings, mouse button actions, key remaps) suspended until
/// it stops.
final class ShortcutRecorder {
    /// What is suspended while recording.
    struct Pauses: OptionSet {
        let rawValue: Int
        /// Bound shortcuts reach the window instead of running.
        static let keyBindings = Pauses(rawValue: 1)
        /// Mapped mouse buttons reach the window instead of running.
        static let buttons = Pauses(rawValue: 2)
        /// The physical keys are recorded, not what they are remapped to.
        static let remaps = Pauses(rawValue: 4)
    }

    private let eventTap: EventTap
    private let remapper: KeyboardRemapper?
    private let monitor = LocalEventMonitor()
    private var paused: Pauses = []

    init(eventTap: EventTap, remapper: KeyboardRemapper? = nil) {
        self.eventTap = eventTap
        self.remapper = remapper
    }

    deinit { stop() }

    /// Hands every `mask` event to `handler` (true: consumed) until `stop`, with `pauses`
    /// suspended. The repeats of a key held down are swallowed: a key held a moment too long
    /// is one press, not the next thing recorded too.
    func start(_ mask: NSEvent.EventTypeMask, pausing pauses: Pauses, _ handler: @escaping (NSEvent) -> Bool) {
        stop()
        if pauses.contains(.keyBindings) { eventTap.setKeyBindingsSuspended(true) }
        if pauses.contains(.buttons) { eventTap.setButtonsSuspended(true) }
        if pauses.contains(.remaps) { remapper?.suspend() }
        paused = pauses
        monitor.start(mask) { event in
            if event.type == .keyDown, event.isARepeat { return true }
            return handler(event)
        }
    }

    /// Records shortcut presses with key bindings suspended (remaps stay on, so caps lock →
    /// ⌃⌥⇧ counts). A key with no name beeps, and so does, with `refusingTypingKeys`, a key
    /// that types on its own (see `typesText`); every other press goes to `handle`.
    func startShortcut(refusingTypingKeys: Bool = false, _ handle: @escaping (ShortcutInput) -> Void) {
        start(.keyDown, pausing: .keyBindings) { event in
            let modifiers = Modifiers(event.modifierFlags)
            guard let name = KeyCodes.name(forKeyCode: event.keyCode),
                  !(refusingTypingKeys && Self.typesText(key: name, modifiers: modifiers)) else {
                NSSound.beep()
                return true
            }
            handle(Self.input(key: name, modifiers: modifiers))
            return true
        }
    }

    /// Escape alone cancels, Delete alone clears; anything else is a shortcut.
    static func input(key: String, modifiers: Modifiers) -> ShortcutInput {
        switch (key, modifiers.isEmpty) {
        case ("escape", true): return .cancel
        case ("delete", true): return .clear
        default: return .keys(modifiers.text(key: key))
        }
    }

    /// Whether `key` with `modifiers` types text: a letter, digit, symbol, keypad key, Space,
    /// Return or Tab, alone or with Shift only. As a global shortcut it could no longer be
    /// typed, so the window pages refuse it. Function, navigation and editing keys do not count.
    static func typesText(key: String, modifiers: Modifiers) -> Bool {
        modifiers.subtracting(.shift).isEmpty && typingKeys.contains(key)
    }

    private static let typingKeys: Set<String> = {
        let groups = ["Letters & Digits", KeyCodes.punctuationGroup, KeyCodes.keypadGroup]
        var keys = Set(groups.flatMap { KeyCodes.keys(inGroup: $0).map(\.name) })
        keys.formUnion(["return", "tab", "space"])
        keys.remove("keypad_clear")
        return keys
    }()

    /// Stops listening and resumes what was suspended.
    func stop() {
        monitor.stop()
        if paused.contains(.keyBindings) { eventTap.setKeyBindingsSuspended(false) }
        if paused.contains(.buttons) { eventTap.setButtonsSuspended(false) }
        if paused.contains(.remaps) { remapper?.resume() }
        paused = []
    }

    /// The hint under every list of shortcut caps.
    static let hint = "Click a shortcut and press the keys. Esc cancels, Delete clears it. A key that types (a letter, Space…) needs a modifier other than Shift."
}

/// The key press or click a settings model is recording: which field, with the recorder that
/// listens for it. Shared by the Keyboard, Mouse and window models, so the rules of a capture
/// are the same on every page: one field at a time, and when a capture ends with nothing
/// recorded the model drops its incomplete rows and catches up with the file (`onEnd`).
///
/// Its own object, so a capture starting, ending or showing the modifiers held redraws the
/// views that observe it (the rows with key caps), not everything observing the page's model.
final class FieldCapture<Field: Equatable>: ObservableObject {
    /// The field being recorded, if any.
    @Published private(set) var field: Field?
    /// What is held so far, shown live in the cap ("⌃⌥⇧"); cleared when the capture ends.
    @Published var preview = ""

    let recorder: ShortcutRecorder
    /// A capture ended with nothing recorded (the cap clicked again, Esc, another page, the
    /// window closed or no longer key), or gave way to the capture of `next`: the model
    /// removes the rows left incomplete, except the one `next` belongs to, and applies a
    /// reload that waited.
    var onEnd: ((_ next: Field?) -> Void)?

    init(recorder: ShortcutRecorder) {
        self.recorder = recorder
    }

    /// `field` is the one recorded from now on; the model then starts the recorder. A capture
    /// in progress ends first.
    func begin(_ field: Field) {
        stop(keeping: field)
        preview = ""
        self.field = field
    }

    /// Ends the capture with nothing recorded.
    func stop() {
        stop(keeping: nil)
    }

    private func stop(keeping next: Field?) {
        guard end() else { return }
        onEnd?(next)
    }

    /// Stops listening, without `onEnd` (the model is about to store what was recorded, or to
    /// remove the row); false when nothing was being recorded.
    @discardableResult
    func end() -> Bool {
        recorder.stop()
        guard field != nil else { return false }
        field = nil
        if !preview.isEmpty { preview = "" }
        return true
    }
}

/// A settings model that records the next key or click for one field at a time.
protocol CaptureModel: AnyObject {
    associatedtype Field: Equatable
    var capture: FieldCapture<Field> { get }
    func startCapture(_ field: Field)
}

extension CaptureModel {
    var capturing: Field? { capture.field }

    /// A click on a key cap: stops recording that field when it is the one recording, else starts.
    func toggleCapture(_ field: Field) {
        capturing == field ? capture.stop() : startCapture(field)
    }
}

extension FileBackedModel where Self: CaptureModel {
    /// Recording ends with nothing recorded. As on every page, a row left incomplete goes: it
    /// was never saved.
    func stopCapture() {
        capture.stop()
    }

    var isEditing: Bool { capture.field != nil }
}
