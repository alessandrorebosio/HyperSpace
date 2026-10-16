import AppKit
import HyperSpaceCore

/// Applies an `InputPlan` to every input layer:
/// - L0, no permission: key mappings (`HIDMapper`), pointer speed (`PointerSettings`) and
///   Logitech controls over HID++ (`LogitechControls`);
/// - L1, Accessibility: keyboard and mouse remapping in the event tap (`InputTap`), kept in
///   sync with the frontmost app.
@MainActor
public final class InputService {
    public enum TapState: String, Sendable {
        case off, running, failed
    }

    private let log = HyperSpace.logger("input")
    private let services = HIDServices()
    private lazy var mapper = HIDMapper(services: services)
    private lazy var pointer = PointerSettings(services: services)
    private let capsLock = CapsLockState()
    private var logitech: LogitechControls?
    private var tap: InputTap?
    private var plan = InputPlan()
    private var frontmostApp = NSWorkspace.shared.frontmostApplication
    private var appObserver: (any NSObjectProtocol)?
    private let onWMCommand: @MainActor @Sendable (String) -> Void
    /// The window manager's binding mode: which hotkey table the tap uses.
    private var mode = "main"
    /// Pointer moves for focus-follows-mouse; nil when nobody needs them.
    private var trackMouse: (@MainActor @Sendable (CGPoint) -> Void)?

    public private(set) var tapState = TapState.off
    public var mappedKeyboards: Int { mapper.mappedKeyboards }

    /// `display_keys`: media keys for external displays (see `InputTap`).
    private let displayKeys: @Sendable (Int32, Bool, CGPoint) -> Bool

    public init(displayKeys: @escaping @Sendable (Int32, Bool, CGPoint) -> Bool, onWMCommand: @escaping @MainActor @Sendable (String) -> Void) {
        self.displayKeys = displayKeys
        self.onWMCommand = onWMCommand
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostApp = app
                self?.pushTables()
            }
        }
    }

    /// - Parameter trackMouse: gets pointer moves (throttled), for focus-follows-mouse.
    public func apply(_ plan: InputPlan, accessibilityGranted: Bool,
                      trackMouse: (@MainActor @Sendable (CGPoint) -> Void)? = nil) {
        let restartTap = needsMoves(plan, trackMouse) != needsMoves(self.plan, self.trackMouse)
            || plan.keyboard.displayKeys != self.plan.keyboard.displayKeys
        self.plan = plan
        self.trackMouse = trackMouse
        if restartTap { stopTap() } // the event mask changes
        if plan.needsEventTap || trackMouse != nil, accessibilityGranted {
            startTap()
        } else {
            stopTap()
        }
        pointer.apply(plan.mouse.pointer)
        // Caps Lock -> F18 and diverted Logitech controls only while the tap is there to give
        // them a meaning; otherwise they would just go dead.
        let running = tapState == .running
        mapper.apply(running ? plan.keyboard.hid : plan.keyboard.hid.filter { $0.to != KeyNames.key(code: Layer.capsLockTrigger)?.usage })
        if running, !plan.mouse.logitech.isEmpty {
            if logitech == nil {
                logitech = LogitechControls { [weak tap = self.tap] index, down in tap?.logitechButton(index, down: down) }
            }
            logitech?.apply(plan.mouse.logitech)
        } else {
            logitech?.stop()
            logitech = nil
        }
        // Remapped Caps Lock: turn off a caps lock that was on before, LED included.
        if running, plan.keyboard.capsLock != nil { capsLock.set(false) }
        pushTables()
    }

    /// The window manager switched binding mode.
    public func setMode(_ mode: String) {
        self.mode = mode
        pushTables()
    }

    private func needsMoves(_ plan: InputPlan, _ track: ((CGPoint) -> Void)?) -> Bool {
        plan.mouse.needsMoveEvents || track != nil
    }

    /// Performs an output now, as if a mapped input fired (`hsctl do`). False if it needs
    /// the event tap and the tap isn't running.
    public func run(_ output: Output) -> Bool {
        switch output {
        case .shell, .wm, .app:
            perform(output)
            return true
        default:
            return tap?.run(output) ?? false
        }
    }

    public func shutdown() {
        logitech?.stop()
        logitech = nil
        stopTap()
        mapper.restore()
        pointer.restore()
    }

    private func perform(_ output: Output) {
        switch output {
        case let .shell(command): ActionRunner.shell(command)
        case let .app(name): ActionRunner.open(app: name)
        case let .wm(command): onWMCommand(command)
        default: break
        }
    }

    private func startTap() {
        guard tap == nil else { return }
        var mouseMoved: (@Sendable (CGPoint) -> Void)?
        if let track = trackMouse {
            mouseMoved = { point in Task { @MainActor in track(point) } }
        }
        let tap = InputTap(capsLock: capsLock, moveEvents: needsMoves(plan, trackMouse), mouseMoved: mouseMoved,
                           displayKeys: plan.keyboard.displayKeys ? displayKeys : nil) { [weak self] output in
            Task { @MainActor in self?.perform(output) }
        }
        if tap.start() {
            self.tap = tap
            tapState = .running
            log.info("event tap running")
            // The Logitech reader posts to the tap it was made with.
            logitech?.stop()
            logitech = nil
        } else {
            tapState = .failed
            log.error("event tap could not be created")
        }
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        tapState = .off
    }

    private func pushTables() {
        tap?.update(plan.tables(forApp: frontmostApp?.bundleIdentifier, mode: mode),
                    frontmostPID: frontmostApp?.processIdentifier ?? 0)
    }
}
