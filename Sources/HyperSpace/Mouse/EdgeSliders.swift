import AppKit
import os

/// The trackpad edge sliders and corners: one finger slid along an edge changes the volume or
/// the display brightness, or seeks (see `EdgeSliderTracker`); a double tap in a corner runs
/// its action (see `CornerTapTracker`).
///
/// macOS offers no public API for the fingers on a trackpad outside an app's own windows, so the
/// touches come from the private MultitouchSupport framework (as in BetterTouchTool and
/// MiddleClick), loaded at run time: if it is missing or changed, the sliders just do nothing.
/// Its callbacks arrive on a thread of its own; the notches are posted on the main thread as the
/// system's own volume and brightness keys, so macOS shows its usual indicator.
/// While a slider or a corner tap is in progress the pointer is held still by the event tap
/// (`onHoldChange`), which also drops the clicks a corner tap makes (`onCornerClicksHeld`).
/// Trackpads are only watched while a slider or a corner is on; ones connected later are picked
/// up from IOKit match notifications and on wake.
final class EdgeSliders {
    /// The one instance the C callback reaches (MultitouchSupport's callback has no context
    /// pointer). Set on the main thread before any trackpad is registered and read on the
    /// multitouch thread, hence the lock.
    fileprivate static let shared = OSAllocatedUnfairLock<EdgeSliders?>(initialState: nil)

    private struct State {
        /// The edges' actions (all `none` with the sliders off) and the corners'.
        var sliders = EdgeSliderTracker(left: .none, right: .none)
        var corners: [TrackpadCorner: Action] = [:]
        /// By device address.
        var trackers: [Int: EdgeSliderTracker] = [:]
        var cornerTrackers: [Int: CornerTapTracker] = [:]
        var holding = false
        var holdingClicks = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// The private framework, loaded the first time a slider or a corner is on (main thread).
    private lazy var api = MultitouchAPI.load()
    /// Main thread: the devices being listened to, kept alive by their list.
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var config = TrackpadConfig()
    /// Set while a slider is on: trackpads connected later, and wakes, restart the listening.
    private var deviceWatcher: DeviceWatcher?
    private let restartDebouncer = Debouncer(delay: 1)

    /// Called when a slider starts or ends, to hold the pointer still meanwhile; on the
    /// multitouch thread (or the main thread when the sliders stop), so it must be thread-safe.
    private let onHoldChange: (Bool) -> Void
    /// Called when a finger goes down in a corner with an action (true) or leaves it (false;
    /// `grace` when lifted from what may be a tap); thread-safe like `onHoldChange`.
    private let onCornerClicksHeld: (_ held: Bool, _ grace: Bool) -> Void
    /// A corner's action, on the main thread.
    private let onAction: (Action) -> Void

    init(onHoldChange: @escaping (Bool) -> Void, onCornerClicksHeld: @escaping (Bool, Bool) -> Void,
         onAction: @escaping (Action) -> Void) {
        self.onHoldChange = onHoldChange
        self.onCornerClicksHeld = onCornerClicksHeld
        self.onAction = onAction
        Self.shared.withLock { $0 = self }
    }

    /// The trackpads listened to.
    var deviceCount: Int { devices.count }
    /// Whether MultitouchSupport loads (loading it if it has not been yet).
    var isAvailable: Bool { api != nil }

    func apply(_ newConfig: TrackpadConfig) {
        config = newConfig
        let on = newConfig.edgeSliders
        let sliders = EdgeSliderTracker(left: on ? newConfig.leftEdge : .none, right: on ? newConfig.rightEdge : .none,
                                        top: on ? newConfig.topEdge : .none, bottom: on ? newConfig.bottomEdge : .none)
        state.withLock { state in
            state.sliders = sliders
            state.corners = newConfig.corners
            for key in state.trackers.keys {
                state.trackers[key]?.left = sliders.left
                state.trackers[key]?.right = sliders.right
                state.trackers[key]?.top = sliders.top
                state.trackers[key]?.bottom = sliders.bottom
            }
            for key in state.cornerTrackers.keys {
                state.cornerTrackers[key]?.corners = Set(newConfig.corners.keys)
            }
        }
        if newConfig.isActive {
            if devices.isEmpty { start() }
            if deviceWatcher == nil {
                deviceWatcher = DeviceWatcher(matching: "AppleMultitouchDevice") { [weak self] in self?.scheduleRestart() }
            }
        } else {
            stop()
            deviceWatcher = nil
        }
    }

    /// Stops listening and lets the pointer go (on quit too).
    func stop() {
        restartDebouncer.cancel()
        // Not `api`: stopping must not load the framework when nothing was ever started.
        if !devices.isEmpty, let api {
            for device in devices {
                api.unregister(device, contactCallback)
                _ = api.stop(device)
            }
        }
        devices = []
        deviceList = nil
        state.withLock { $0.trackers = [:]; $0.cornerTrackers = [:]; $0.holding = false; $0.holdingClicks = false }
        onHoldChange(false)
        onCornerClicksHeld(false, false)
    }

    private func start() {
        guard let api, let list = api.createList()?.takeRetainedValue() else {
            log.error("edge sliders: MultitouchSupport is not available")
            return
        }
        deviceList = list
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var family: Int32 = 0
            _ = api.familyID(device, &family)
            // The Magic Mouse has a touch surface too: the sliders are for trackpads.
            if MultitouchAPI.mouseFamilies.contains(family) { continue }
            api.register(device, contactCallback)
            let status = api.start(device, 0)
            guard status == 0 else {
                log.error("edge sliders: a trackpad (family \(family)) did not start: \(status)")
                api.unregister(device, contactCallback)
                continue
            }
            devices.append(device)
        }
        log.info("trackpad edges and corners: \(self.devices.count) trackpad(s)")
    }

    /// A trackpad connected (Bluetooth, USB) or the Mac woke: listen again, all of them.
    private func scheduleRestart() {
        restartDebouncer.schedule { [weak self] in
            guard let self, config.isActive else { return }
            stop()
            start()
        }
    }

    /// Multitouch thread: one frame of one trackpad at `time` (seconds). The main thread is
    /// only bothered when a notch is crossed or a corner double-tapped (frames come about 100
    /// times a second).
    fileprivate func frame(_ device: UnsafeMutableRawPointer, first: EdgeTouch?, count: Int, time: Double) {
        let key = Int(bitPattern: device)
        // A finger pressing the trackpad is a click or a click-drag, not a slide or a tap.
        let pressed = count > 0 && NSEvent.pressedMouseButtons != 0
        typealias Result = (steps: [EdgeStep], action: Action?, hold: Bool?, clicks: Bool?)
        let result = state.withLock { state -> Result in
            var tracker = state.trackers[key] ?? state.sliders
            let steps = tracker.update(first: first, count: count, pressed: pressed)
            state.trackers[key] = tracker
            var corners = state.cornerTrackers[key] ?? CornerTapTracker(corners: Set(state.corners.keys))
            let corner = corners.update(first: first, count: count, pressed: pressed, time: time)
            state.cornerTrackers[key] = corners
            let holdingClicks = state.cornerTrackers.values.contains { $0.holding }
            let holding = holdingClicks || state.trackers.values.contains { $0.holding }
            defer { state.holding = holding; state.holdingClicks = holdingClicks }
            return (steps, corner.flatMap { state.corners[$0] },
                    holding != state.holding ? holding : nil,
                    holdingClicks != state.holdingClicks ? holdingClicks : nil)
        }
        // Straight to the event tap: the sooner the hold starts, the less the pointer moves.
        if let hold = result.hold { onHoldChange(hold) }
        // Lifted (no finger left): what may be a tap clicks now with tap to click.
        if let clicks = result.clicks { onCornerClicksHeld(clicks, !clicks && count == 0) }
        guard !result.steps.isEmpty || result.action != nil else { return }
        let onAction = onAction
        DispatchQueue.main.async {
            for step in result.steps { Self.post(step) }
            if let action = result.action { onAction(action) }
        }
    }

    /// The arrows a seek posts.
    private static let rightArrow: UInt16 = 0x7C
    private static let leftArrow: UInt16 = 0x7B

    private static func post(_ step: EdgeStep) {
        switch step.action {
        case .volume: (step.up ? MediaKey.volumeUp : .volumeDown).post()
        case .brightness: (step.up ? MediaKey.brightnessUp : .brightnessDown).post()
        case .seek:
            let key = step.up ? rightArrow : leftArrow
            KeyEmitter.post(keyCode: key, flags: [], down: true)
            KeyEmitter.post(keyCode: key, flags: [], down: false)
        case .none: break
        }
    }
}

/// The functions of MultitouchSupport.framework, looked up at run time.
private struct MultitouchAPI {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    /// Family ids of the Magic Mouse models.
    static let mouseFamilies: Set<Int32> = [112, 113]

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    let unregister: @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32
    let familyID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32

    static func load() -> MultitouchAPI? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let createList = symbol("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
              let register = symbol("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self),
              let unregister = symbol("MTUnregisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self),
              let start = symbol("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self),
              let stop = symbol("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self),
              let familyID = symbol("MTDeviceGetFamilyID", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self)
        else { return nil }
        return MultitouchAPI(createList: createList, register: register, unregister: unregister,
                             start: start, stop: stop, familyID: familyID)
    }
}

/// `MTTouch` of MultitouchSupport: 96 bytes per finger. Read by offset, the struct being private.
private enum TouchLayout {
    static let stride = 96
    static let identifier = 16
    static let state = 20
    static let normalizedX = 32
    static let normalizedY = 36
    /// States 3 (making touch) and 4 (touching): the finger is on the surface.
    static let onSurface: ClosedRange<Int32> = 3...4
}

private let contactCallback: MultitouchAPI.Callback = { device, touches, count, time, _ in
    guard let device, let sliders = EdgeSliders.shared.withLock({ $0 }) else { return 0 }
    // Only the number of fingers on the surface and the first of them: nothing is allocated
    // per frame (about 100 a second).
    var first: EdgeTouch?
    var fingers = 0
    if let touches, count > 0 {
        for index in 0..<Int(count) {
            let base = touches + index * TouchLayout.stride
            let state = base.load(fromByteOffset: TouchLayout.state, as: Int32.self)
            guard TouchLayout.onSurface.contains(state) else { continue }
            fingers += 1
            if first == nil {
                first = EdgeTouch(id: base.load(fromByteOffset: TouchLayout.identifier, as: Int32.self),
                                  x: base.load(fromByteOffset: TouchLayout.normalizedX, as: Float.self),
                                  y: base.load(fromByteOffset: TouchLayout.normalizedY, as: Float.self))
            }
        }
    }
    sliders.frame(device, first: first, count: fingers, time: time)
    return 0
}
