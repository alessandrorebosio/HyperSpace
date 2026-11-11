import AppKit
import os

/// The trackpad edge sliders: one finger slid up or down along the left or right edge changes
/// the volume or the display brightness (see `EdgeSliderTracker`).
///
/// macOS offers no public API for the fingers on a trackpad outside an app's own windows, so the
/// touches come from the private MultitouchSupport framework (as in BetterTouchTool and
/// MiddleClick), loaded at run time: if it is missing or changed, the sliders just do nothing.
/// Its callbacks arrive on a thread of its own; the notches are posted on the main thread as the
/// system's own volume and brightness keys, so macOS shows its usual indicator.
/// While a slider is in progress the pointer is held still by the event tap (`onHoldChange`).
/// Trackpads are only watched while a slider is on; ones connected later are picked up from
/// IOKit match notifications and on wake.
final class EdgeSliders {
    /// The one instance the C callback reaches.
    fileprivate static var shared: EdgeSliders?

    private struct State {
        var left = TrackpadConfig.defaultLeftEdge
        var right = TrackpadConfig.defaultRightEdge
        /// By device address.
        var trackers: [Int: EdgeSliderTracker] = [:]
        var holding = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let api = MultitouchAPI.load()
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

    init(onHoldChange: @escaping (Bool) -> Void) {
        self.onHoldChange = onHoldChange
        Self.shared = self
    }

    /// The trackpads listened to.
    var deviceCount: Int { devices.count }
    var isAvailable: Bool { api != nil }

    func apply(_ newConfig: TrackpadConfig) {
        config = newConfig
        state.withLock { state in
            state.left = newConfig.leftEdge
            state.right = newConfig.rightEdge
            for key in state.trackers.keys {
                state.trackers[key]?.left = newConfig.leftEdge
                state.trackers[key]?.right = newConfig.rightEdge
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
        if let api {
            for device in devices {
                api.unregister(device, contactCallback)
                _ = api.stop(device)
            }
        }
        devices = []
        deviceList = nil
        state.withLock { $0.trackers = [:]; $0.holding = false }
        onHoldChange(false)
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
            _ = api.start(device, 0)
            devices.append(device)
        }
        log.info("edge sliders: \(self.devices.count) trackpad(s)")
    }

    /// A trackpad connected (Bluetooth, USB) or the Mac woke: listen again, all of them.
    private func scheduleRestart() {
        restartDebouncer.schedule { [weak self] in
            guard let self, config.isActive else { return }
            stop()
            start()
        }
    }

    /// Multitouch thread: one frame of one trackpad. The main thread is only bothered when a
    /// notch is crossed (frames come about 100 times a second).
    fileprivate func frame(_ device: UnsafeMutableRawPointer, first: EdgeTouch?, count: Int) {
        let key = Int(bitPattern: device)
        let (steps, holdChange) = state.withLock { state -> ([EdgeStep], Bool?) in
            var tracker = state.trackers[key] ?? EdgeSliderTracker(left: state.left, right: state.right)
            let steps = tracker.update(first: first, count: count)
            state.trackers[key] = tracker
            let holding = state.trackers.values.contains { $0.holding }
            defer { state.holding = holding }
            return (steps, holding != state.holding ? holding : nil)
        }
        // Straight to the event tap: the sooner the hold starts, the less the pointer moves.
        if let holdChange { onHoldChange(holdChange) }
        guard !steps.isEmpty else { return }
        DispatchQueue.main.async {
            for step in steps { Self.post(step) }
        }
    }

    private static func post(_ step: EdgeStep) {
        switch step.action {
        case .volume: (step.up ? MediaKey.volumeUp : .volumeDown).post()
        case .brightness: (step.up ? MediaKey.brightnessUp : .brightnessDown).post()
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

private let contactCallback: MultitouchAPI.Callback = { device, touches, count, _, _ in
    guard let device, let sliders = EdgeSliders.shared else { return 0 }
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
    sliders.frame(device, first: first, count: fingers)
    return 0
}
