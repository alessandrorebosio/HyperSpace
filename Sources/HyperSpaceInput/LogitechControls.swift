import Foundation
import HyperSpaceCore
import IOKit.hid

/// Logitech controls that never reach macOS on their own, like the Lift's DPI button, read
/// over HID++ 2.0 (see docs/SPIKE.md, S3). No permission needed: the receiver's vendor
/// interface (usage page 0xFF00) isn't a keyboard or mouse interface.
///
/// For each configured control the device is told to "divert" it (feature 0x1B04,
/// Reprogrammable Keys): instead of doing its firmware job it reports presses to the host as
/// `divertedButtons` events, which become `onButton` calls. Diversion is undone on `stop()`
/// and redone when a device reconnects (it resets on power cycles and sleep).
///
/// Everything runs on its own thread: the first request to a sleeping device can take
/// seconds, and the input thread must never wait for it.
final class LogitechControls: @unchecked Sendable {
    private let log = HyperSpace.logger("logitech")
    private let onButton: @Sendable (_ index: Int, _ down: Bool) -> Void

    // HID++ thread only.
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    /// Control id -> button index (`MouseButtons`), from the plan.
    private var controls: [UInt16: Int] = [:]
    private var targets: [Target] = []
    private var inbox: [(IOHIDDevice, [UInt8])] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    /// One device behind a receiver slot (or a Bluetooth device, index 0xFF).
    private struct Target {
        let device: IOHIDDevice
        let index: UInt8
        /// Index of feature 0x1B04 on this device.
        let feature: UInt8
        let divertable: Set<UInt16>
        var diverted: Set<UInt16> = []
        var held: Set<UInt16> = []
    }

    private enum HIDPP {
        static let shortReport: UInt8 = 0x10
        static let longReport: UInt8 = 0x11
        /// Our software id: responses carry it back, notifications carry 0. Other apps
        /// (Logi Options+) use their own, so their traffic is ignored.
        static let softwareID: UInt8 = 0x0A
        static let reprogrammableKeys: UInt16 = 0x1B04
        /// Receiver notification: a paired device connected or woke up.
        static let deviceConnection: UInt8 = 0x41
        /// Run loop mode for waiting on a response: only device reports are handled in it,
        /// so nothing else re-enters while a request is in flight.
        nonisolated(unsafe) static let waitMode = "hyperspace.hidpp.wait" as CFString
    }

    init(onButton: @escaping @Sendable (_ index: Int, _ down: Bool) -> Void) {
        self.onButton = onButton
    }

    /// Diverts exactly these controls (control id -> button index). Empty stops everything.
    func apply(_ controls: [UInt16: Int]) {
        if controls.isEmpty {
            stop()
            return
        }
        if runLoop == nil { startThread() }
        perform { [self] in
            self.controls = controls
            for i in targets.indices { divert(&targets[i]) }
        }
    }

    /// Restores every control's firmware behavior and closes the devices.
    func stop() {
        guard runLoop != nil else { return }
        let done = DispatchSemaphore(value: 0)
        perform { [self] in
            controls = [:]
            for i in targets.indices { divert(&targets[i]) }
            targets = []
            if let manager { IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }
            manager = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        self.runLoop = nil
    }

    // MARK: - Thread

    private func startThread() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            openManager()
            ready.signal()
            CFRunLoopRun()
            buffers.forEach { $0.deallocate() }
            buffers = []
        }
        thread.name = "hyperspace.logitech"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func openManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF00], // receivers
            [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF43], // Bluetooth devices
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let controls = Unmanaged<LogitechControls>.fromOpaque(context!).takeUnretainedValue()
            // Probing waits for responses: not from inside the matching callback.
            controls.perform { controls.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let controls = Unmanaged<LogitechControls>.fromOpaque(context!).takeUnretainedValue()
            controls.targets.removeAll { $0.device == device }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
    }

    // MARK: - Devices

    /// Finds the devices behind a receiver (slots 1...6) or the device itself (0xFF) that have
    /// Reprogrammable Keys, and diverts the configured controls on them.
    private func attach(_ device: IOHIDDevice) {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log.error("cannot open a Logitech receiver")
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers.append(buffer)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, sender, _, _, report, length in
            let controls = Unmanaged<LogitechControls>.fromOpaque(context!).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender!).takeUnretainedValue()
            controls.received(device, Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        for mode in [CFRunLoopMode.defaultMode.rawValue, HIDPP.waitMode] {
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), mode)
        }
        for index in [UInt8(0xFF)] + Array(1...6) { probe(device, index: index) }
    }

    private func probe(_ device: IOHIDDevice, index: UInt8) {
        targets.removeAll { $0.device == device && $0.index == index }
        // IRoot.getProtocolVersion: HID++ 2.0 devices answer with major >= 2.
        guard let ping = request(device, index, feature: 0, function: 1, params: [0, 0, 0xAA], timeout: 2),
              ping[4] >= 2,
              let feature = request(device, index, feature: 0, function: 0,
                                    params: [UInt8(HIDPP.reprogrammableKeys >> 8), UInt8(HIDPP.reprogrammableKeys & 0xFF)])?[4],
              feature != 0,
              let count = request(device, index, feature: feature, function: 0)?[4] else { return }
        var divertable = Set<UInt16>()
        for i in 0..<count {
            guard let info = request(device, index, feature: feature, function: 1, params: [i]) else { continue }
            if info[8] & 0x20 != 0 { divertable.insert(UInt16(info[4]) << 8 | UInt16(info[5])) } // flag: divertable
        }
        var target = Target(device: device, index: index, feature: feature, divertable: divertable)
        divert(&target)
        targets.append(target)
        log.info("Logitech device in slot \(index): \(divertable.count) divertable control(s)")
    }

    /// Diverts the configured controls and gives the others back to the firmware.
    private func divert(_ target: inout Target) {
        let wanted = Set(controls.keys).intersection(target.divertable)
        for cid in target.diverted.subtracting(wanted) where setReporting(target, cid, divert: false) {
            target.diverted.remove(cid)
        }
        for cid in wanted.subtracting(target.diverted) where setReporting(target, cid, divert: true) {
            target.diverted.insert(cid)
        }
        target.held.formIntersection(target.diverted)
    }

    /// setCidReporting (function 3): 0x03 = divert, 0x02 = back to the firmware.
    private func setReporting(_ target: Target, _ cid: UInt16, divert: Bool) -> Bool {
        request(target.device, target.index, feature: target.feature, function: 3,
                params: [UInt8(cid >> 8), UInt8(cid & 0xFF), divert ? 0x03 : 0x02]) != nil
    }

    // MARK: - Reports

    private func received(_ device: IOHIDDevice, _ report: [UInt8]) {
        guard report.count >= 4 else { return }
        // A device behind a receiver (re)connected: its diversion is gone, redo it.
        if report[0] == HIDPP.shortReport, report[2] == HIDPP.deviceConnection, report.count >= 5, report[4] & 0x40 == 0 {
            let index = report[1]
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.5, 0, 0, 0) { [self] _ in
                if manager != nil, !controls.isEmpty { probe(device, index: index) }
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            return
        }
        // divertedButtons notification: function 0, software id 0, up to 4 held control ids.
        guard report[0] == HIDPP.longReport, report.count >= 12, report[3] == 0,
              let i = targets.firstIndex(where: { $0.device == device && $0.index == report[1] && $0.feature == report[2] }) else {
            inbox.append((device, report))
            return
        }
        let held = Set(stride(from: 4, to: 12, by: 2).map { UInt16(report[$0]) << 8 | UInt16(report[$0 + 1]) }.filter { $0 != 0 })
        for cid in held.subtracting(targets[i].held) { if let index = controls[cid] { onButton(index, true) } }
        for cid in targets[i].held.subtracting(held) { if let index = controls[cid] { onButton(index, false) } }
        targets[i].held = held
    }

    /// Sends a long HID++ request and waits for its response (matched by device index,
    /// feature, function and our software id), or an error, or the timeout.
    private func request(_ device: IOHIDDevice, _ index: UInt8, feature: UInt8, function: UInt8,
                         params: [UInt8] = [], timeout: Double = 1) -> [UInt8]? {
        let tag = function << 4 | HIDPP.softwareID
        var message: [UInt8] = [HIDPP.longReport, index, feature, tag] + params
        message += [UInt8](repeating: 0, count: 20 - message.count)
        inbox.removeAll()
        let sent = message.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HIDPP.longReport), $0.baseAddress!, $0.count)
        }
        guard sent == kIOReturnSuccess else { return nil }

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode(HIDPP.waitMode), 0.01, true)
            while !inbox.isEmpty {
                let (from, m) = inbox.removeFirst()
                guard from == device, m.count >= 6, m[1] == index else { continue }
                if m[2] == feature, m[3] == tag { return m }
                // HID++ 2.0 error (0xFF) or HID++ 1.0 error (0x8F) for this request.
                if m[2] == 0xFF || m[2] == 0x8F, m[3] == feature, m[4] == tag { return nil }
            }
        }
        return nil
    }
}
