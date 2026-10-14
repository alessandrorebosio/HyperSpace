import Foundation
import IOKit.hid

/// S3: Logitech HID++ 2.0 over the vendor collection (Bolt/Unifying receiver or Bluetooth).
/// Lists the controls of feature 0x1B04 (Reprogrammable Keys) and can divert them to the host.
enum HIDPP {
    static let shortReport: UInt8 = 0x10
    static let longReport: UInt8 = 0x11
    static let swid: UInt8 = 0x0A
    static let reprogKeys: UInt16 = 0x1B04
    static let deviceName: UInt16 = 0x0005
    /// Never divert left/right click: the mouse would become unusable during the spike.
    static let neverDivert: Set<UInt16> = [0x50, 0x51]

    static var inbox: [[UInt8]] = []
    static let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    static var stop = false

    struct Control {
        let cid: UInt16
        let tid: UInt16
        let flags: UInt8
        let extraFlags: UInt8
        var divertable: Bool { flags & 0x20 != 0 }
    }

    static func run(listen: Double?) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF43],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        print("\(devices.count) Logitech vendor interface(s)")

        for device in devices {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            print("\n\(HIDRaw.describe(device)) open: \(ioReturnName(result))")
            guard result == kIOReturnSuccess else { continue }
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, reportCallback, nil)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

            // 0xFF = the device itself (Bluetooth) or the receiver; 1...6 = receiver pairing slots.
            for index in [UInt8(0xFF)] + Array(1...6) {
                probe(device, index: index, listen: listen)
            }
        }
    }

    static func probe(_ device: IOHIDDevice, index: UInt8, listen: Double?) {
        // IRoot.getProtocolVersion (feature index 0, function 1)
        guard let ping = request(device, index: index, feature: 0, function: 1, params: [0, 0, 0xAA], timeout: 2.0) else { return }
        let major = ping[4], minor = ping[5]
        guard major >= 2 else {
            print("  [\(hex(index))] HID++ \(major).\(minor) (receiver / legacy), skipped")
            return
        }
        let name = readName(device, index: index) ?? "?"
        print("  [\(hex(index))] HID++ \(major).\(minor) \"\(name)\"")

        guard let feature = featureIndex(device, index: index, id: reprogKeys) else {
            print("    no Reprogrammable Keys (0x1B04) feature")
            return
        }
        let controls = listControls(device, index: index, feature: feature)
        print("    0x1B04 at feature index \(feature), \(controls.count) control(s):")
        for c in controls {
            print("    CID \(hex(c.cid, width: 4))  TID \(hex(c.tid, width: 4))  flags \(hex(c.flags)) extra \(hex(c.extraFlags))  \(c.divertable ? "divertable" : "-")")
        }
        if let listen { divertAndListen(device, index: index, feature: feature, controls: controls, seconds: listen) }
    }

    static func divertAndListen(_ device: IOHIDDevice, index: UInt8, feature: UInt8, controls: [Control], seconds: Double) {
        let targets = controls.filter { $0.divertable && !neverDivert.contains($0.cid) }
        // setCidReporting (function 3): flags 0x03 = divert + divert valid
        for c in targets {
            let ok = request(device, index: index, feature: feature, function: 3, params: [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF), 0x03]) != nil
            print("    divert \(hex(c.cid, width: 4)): \(ok ? "OK" : "FAILED")")
        }

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { stop = true }
        sigint.resume()

        print("    listening \(Int(seconds))s: press every button (Ctrl-C to stop early)...")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !stop {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            while !inbox.isEmpty {
                let m = inbox.removeFirst()
                guard m.count >= 12, m[1] == index, m[2] == feature, m[3] >> 4 == 0 else { continue }
                // divertedButtons event: up to 4 CIDs currently held
                let held = stride(from: 4, to: 12, by: 2).map { UInt16(m[$0]) << 8 | UInt16(m[$0 + 1]) }.filter { $0 != 0 }
                log("    diverted buttons held: \(held.isEmpty ? "none" : held.map { hex($0, width: 4) }.joined(separator: ", "))")
            }
        }

        // Restore firmware behaviour: flags 0x02 = divert valid, divert off
        for c in targets {
            _ = request(device, index: index, feature: feature, function: 3, params: [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF), 0x02])
        }
        print("    restored \(targets.count) control(s)")
    }

    // MARK: - HID++ 2.0 helpers

    static func featureIndex(_ device: IOHIDDevice, index: UInt8, id: UInt16) -> UInt8? {
        // IRoot.getFeature (function 0)
        guard let r = request(device, index: index, feature: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)]), r[4] != 0 else { return nil }
        return r[4]
    }

    static func readName(_ device: IOHIDDevice, index: UInt8) -> String? {
        guard let feature = featureIndex(device, index: index, id: deviceName),
              let count = request(device, index: index, feature: feature, function: 0)?[4] else { return nil }
        var bytes: [UInt8] = []
        while bytes.count < Int(count) {
            guard let chunk = request(device, index: index, feature: feature, function: 1, params: [UInt8(bytes.count)]) else { break }
            bytes += chunk[4..<min(chunk.count, 20)]
        }
        return String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
    }

    static func listControls(_ device: IOHIDDevice, index: UInt8, feature: UInt8) -> [Control] {
        guard let count = request(device, index: index, feature: feature, function: 0)?[4] else { return [] }
        return (0..<count).compactMap { i in
            guard let r = request(device, index: index, feature: feature, function: 1, params: [i]) else { return nil }
            return Control(
                cid: UInt16(r[4]) << 8 | UInt16(r[5]),
                tid: UInt16(r[6]) << 8 | UInt16(r[7]),
                flags: r[8],
                extraFlags: r[12]
            )
        }
    }

    /// Sends a long HID++ request and waits for the matching response.
    static func request(_ device: IOHIDDevice, index: UInt8, feature: UInt8, function: UInt8,
                        params: [UInt8] = [], timeout: Double = 1.0) -> [UInt8]? {
        let tag = function << 4 | swid
        var message: [UInt8] = [longReport, index, feature, tag] + params
        message += [UInt8](repeating: 0, count: 20 - message.count)

        inbox.removeAll()
        let result = message.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(longReport), $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else {
            print("    setReport failed: \(ioReturnName(result))")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            while !inbox.isEmpty {
                let m = inbox.removeFirst()
                guard m.count >= 6, m[1] == index else { continue }
                if m[2] == feature, m[3] == tag { return m }
                // HID++ 2.0 error (0xFF) or HID++ 1.0 error (0x8F) for this request
                if m[2] == 0xFF || m[2] == 0x8F, m[3] == feature, m[4] == tag { return nil }
            }
        }
        return nil
    }

    static let reportCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        if ProcessInfo.processInfo.environment["HIDPP_DEBUG"] != nil { log("    raw: \(hex(bytes))") }
        HIDPP.inbox.append(bytes)
    }
}
