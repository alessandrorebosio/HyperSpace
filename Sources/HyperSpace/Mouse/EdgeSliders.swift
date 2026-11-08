import AppKit
import IOKit
import os

/// The trackpad edge sliders: one finger slid up or down along the left or right edge changes
/// the volume or the display brightness (see `EdgeSliderTracker`).
///
/// macOS offers no public API for the fingers on a trackpad outside an app's own windows, so the
/// touches come from the private MultitouchSupport framework (as in BetterTouchTool and
/// MiddleClick), loaded at run time: if it is missing or changed, the sliders just do nothing.
/// Its callbacks arrive on a thread of its own; the notches are posted on the main thread as the
/// system's own volume and brightness keys, so macOS shows its usual indicator.
/// While a slider is in progress the pointer is held still (`CGAssociateMouseAndMouseCursorPosition`).
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
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?

    init() {
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
            watchDevices()
        } else {
            stop()
            unwatchDevices()
        }
    }

    /// Stops listening and lets the pointer go (on quit too).
    func stop() {
        pendingRestart?.cancel()
        if let api {
            for device in devices {
                api.unregister(device, contactCallback)
                _ = api.stop(device)
            }
        }
        devices = []
        deviceList = nil
        state.withLock { $0.trackers = [:]; $0.holding = false }
        setHolding(false)
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
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, config.isActive else { return }
            stop()
            start()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func watchDevices() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
            { refcon, iterator in
                EdgeSliders.drain(iterator)
                guard let refcon else { return }
                Unmanaged<EdgeSliders>.fromOpaque(refcon).takeUnretainedValue().scheduleRestart()
            },
            Unmanaged.passUnretained(self).toOpaque(), &iterator
        )
        // The notification only arms once the iterator has been drained.
        if result == KERN_SUCCESS { Self.drain(iterator) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRestart() }
    }

    private func unwatchDevices() {
        if iterator != 0 { IOObjectRelease(iterator) }
        iterator = 0
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Multitouch thread: one frame of one trackpad. The main thread is only bothered when a
    /// notch is crossed or the hold starts or ends (frames come about 100 times a second).
    fileprivate func frame(_ device: UnsafeMutableRawPointer, _ touches: [EdgeTouch]) {
        let key = Int(bitPattern: device)
        let (steps, holdChange) = state.withLock { state -> ([EdgeStep], Bool?) in
            var tracker = state.trackers[key] ?? EdgeSliderTracker(left: state.left, right: state.right)
            let steps = tracker.update(touches)
            state.trackers[key] = tracker
            let holding = state.trackers.values.contains { $0.holding }
            defer { state.holding = holding }
            return (steps, holding != state.holding ? holding : nil)
        }
        guard !steps.isEmpty || holdChange != nil else { return }
        DispatchQueue.main.async { [weak self] in
            if let holdChange { self?.setHolding(holdChange) }
            for step in steps { Self.post(step) }
        }
    }

    /// Main thread.
    private func setHolding(_ holding: Bool) {
        CGAssociateMouseAndMouseCursorPosition(holding ? 0 : 1)
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
    var fingers: [EdgeTouch] = []
    if let touches, count > 0 {
        for index in 0..<Int(count) {
            let base = touches + index * TouchLayout.stride
            let state = base.load(fromByteOffset: TouchLayout.state, as: Int32.self)
            guard TouchLayout.onSurface.contains(state) else { continue }
            fingers.append(EdgeTouch(id: base.load(fromByteOffset: TouchLayout.identifier, as: Int32.self),
                                     x: base.load(fromByteOffset: TouchLayout.normalizedX, as: Float.self),
                                     y: base.load(fromByteOffset: TouchLayout.normalizedY, as: Float.self)))
        }
    }
    sliders.frame(device, fingers)
    return 0
}
