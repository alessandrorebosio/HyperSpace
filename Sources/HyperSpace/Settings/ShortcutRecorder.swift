import AppKit

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

    /// Hands every `mask` event to `handler` (true: consumed) until `stop`, with `pauses` suspended.
    func start(_ mask: NSEvent.EventTypeMask, pausing pauses: Pauses, _ handler: @escaping (NSEvent) -> Bool) {
        stop()
        if pauses.contains(.keyBindings) { eventTap.setKeyBindingsSuspended(true) }
        if pauses.contains(.buttons) { eventTap.setButtonsSuspended(true) }
        if pauses.contains(.remaps) { remapper?.suspend() }
        paused = pauses
        monitor.start(mask, handler)
    }

    /// Records shortcut presses with key bindings suspended (remaps stay on, so caps lock →
    /// ⌃⌥⇧ counts). A key with no name beeps; every other press goes to `handle`.
    func startShortcut(_ handle: @escaping (ShortcutInput) -> Void) {
        start(.keyDown, pausing: .keyBindings) { event in
            guard let name = KeyCodes.name(forKeyCode: event.keyCode) else {
                NSSound.beep()
                return true
            }
            handle(Self.input(key: name, modifiers: Modifiers(event.modifierFlags)))
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

    /// Stops listening and resumes what was suspended.
    func stop() {
        monitor.stop()
        if paused.contains(.keyBindings) { eventTap.setKeyBindingsSuspended(false) }
        if paused.contains(.buttons) { eventTap.setButtonsSuspended(false) }
        if paused.contains(.remaps) { remapper?.resume() }
        paused = []
    }

    /// The hint under every list of shortcut caps.
    static let hint = "Click a shortcut and press the keys. Esc cancels, Delete clears it."
}

/// A settings model that records the next key or click for one field at a time.
protocol CaptureModel: AnyObject {
    associatedtype Field: Equatable
    var capturing: Field? { get }
    func startCapture(_ field: Field)
    func stopCapture()
}

extension CaptureModel {
    /// A click on a key cap: stops recording that field when it is the one recording, else starts.
    func toggleCapture(_ field: Field) {
        capturing == field ? stopCapture() : startCapture(field)
    }
}
