import CoreGraphics
import Foundation
import HyperSpaceCore
import IOKit
import Synchronization

/// External displays' own settings over DDC/CI, through the display's I²C channel: the input
/// source it shows (a display switched to another computer often stays connected to macOS,
/// so this is the only way to tell), brightness, speaker volume. Apple silicon only
/// (`IOAVService`, a private API looked up at run time): elsewhere nothing is read or set.
public final class DDC: @unchecked Sendable {
    /// One per process: the I²C channel takes one transaction at a time.
    public static let shared = DDC()

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) } // RTLD_DEFAULT
    }

    private let create = symbol("IOAVServiceCreateWithService", as: Create.self)
    private let readI2C = symbol("IOAVServiceReadI2C", as: Transfer.self)
    private let writeI2C = symbol("IOAVServiceWriteI2C", as: Transfer.self)
    private init() {}

    /// Reads take ~70 ms each: never on the main thread, one display at a time.
    private let queue = DispatchQueue(label: "hyperspace.wm.ddc", qos: .utility)
    /// The AV service of each display, found again only when the displays change.
    private var services: (displays: [CGDirectDisplayID], byDisplay: [CGDirectDisplayID: CFTypeRef]) = ([], [:])

    /// The input of each display that answers, by display id. The built-in one has none, and
    /// asleep ones aren't asked (they wouldn't answer).
    func inputs(of displays: [CGDirectDisplayID], _ completion: @escaping @MainActor ([CGDirectDisplayID: UInt8]) -> Void) {
        queue.async { [self] in
            var inputs: [CGDirectDisplayID: UInt8] = [:]
            if create != nil, readI2C != nil, writeI2C != nil {
                let external = displays.filter { CGDisplayIsBuiltin($0) == 0 }.sorted()
                if services.displays != external { services = (external, findServices(external)) }
                for (display, service) in services.byDisplay where CGDisplayIsAsleep(display) == 0 {
                    if let input = read(0x60, service) { inputs[display] = UInt8(truncatingIfNeeded: input.current) }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(inputs) } }
        }
    }

    /// Changes a display's setting; `done` (main thread) says if the display took it.
    public func set(_ control: WMCommand.MonitorSetting, on display: CGDirectDisplayID, _ done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            let ok = service(of: display).map { apply(control, $0) } ?? false
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } } }
        }
    }

    private func apply(_ control: WMCommand.MonitorSetting, _ service: CFTypeRef) -> Bool {
        func level(_ code: UInt8, _ amount: WMCommand.ResizeAmount) -> Bool {
            guard let value = read(code, service), value.max > 0 else { return false }
            let max = Double(value.max)
            let target = switch amount {
            case let .add(percent): Double(value.current) + percent * max / 100
            case let .set(percent): percent * max / 100
            }
            return write(code, UInt16(Swift.max(0, Swift.min(max, target.rounded()))), service)
        }
        switch control {
        case let .brightness(amount): return level(0x10, amount)
        case let .volume(amount): return level(0x62, amount)
        case .muteToggle:
            // 0x8D: 1 = muted, 2 = not muted.
            guard let value = read(0x8D, service) else { return false }
            return write(0x8D, value.current & 0xff == 1 ? 2 : 1, service)
        case let .input(code): return write(0x60, UInt16(code), service)
        }
    }

    /// Brightness or volume up or down by `percent`, from a key: steps that arrive while
    /// the display is busy (a held key repeats faster than DDC answers) add up into one.
    public func nudge(volume: Bool, by percent: Double, on display: CGDirectDisplayID) {
        let key = Nudge(display: display, volume: volume)
        guard nudges.withLock({ pending in
            defer { pending[key, default: 0] += percent }
            return pending[key] == nil
        }) else { return }
        queue.async { [self] in
            let total = nudges.withLock { $0.removeValue(forKey: key) } ?? 0
            guard let service = service(of: display) else { return }
            _ = apply(volume ? .volume(.add(total)) : .brightness(.add(total)), service)
        }
    }

    private struct Nudge: Hashable {
        let display: CGDirectDisplayID
        let volume: Bool
    }

    private let nudges = Mutex<[Nudge: Double]>([:])

    /// The service of one display, looking again if it's a display not seen yet.
    private func service(of display: CGDirectDisplayID) -> CFTypeRef? {
        guard create != nil, CGDisplayIsBuiltin(display) == 0 else { return nil }
        if let service = services.byDisplay[display] { return service }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.sorted()
        services = (external, findServices(external))
        return services.byDisplay[display]
    }

    /// Each external `DCPAVServiceProxy` follows its framebuffer (`AppleCLCD2`) in the
    /// registry; the framebuffer's EDID attributes tell which display it is.
    private func findServices(_ displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CFTypeRef] {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        typealias EDID = (vendor: UInt32, model: UInt32, serial: UInt32)
        var found: [(edid: EDID?, service: CFTypeRef)] = []
        var lastEDID: EDID?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0 {
                guard property(entry, "Location") as? String == "External",
                      let service = create?(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append((lastEDID, service))
                lastEDID = nil
            } else if IOObjectConformsTo(entry, "AppleCLCD2") != 0 || IOObjectConformsTo(entry, "IOMobileFramebufferShim") != 0 {
                let attributes = property(entry, "DisplayAttributes") as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                func number(_ key: String) -> UInt32? { (product?[key] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.uint64Value) } }
                lastEDID = number("LegacyManufacturerID").map { ($0, number("ProductID") ?? 0, number("SerialNumber") ?? 0) }
            }
        }
        var byDisplay: [CGDirectDisplayID: CFTypeRef] = [:]
        var unmatched = displays
        for (edid, service) in found {
            guard let edid, let index = unmatched.firstIndex(where: {
                CGDisplayVendorNumber($0) == edid.vendor && CGDisplayModelNumber($0) == edid.model && CGDisplaySerialNumber($0) == edid.serial
            }) else { continue }
            byDisplay[unmatched.remove(at: index)] = service
        }
        // One display and one service left over (no EDID attributes): they go together.
        let left = found.filter { pair in !byDisplay.values.contains { $0 === pair.service } }
        if unmatched.count == 1, left.count == 1 { byDisplay[unmatched[0]] = left[0].service }
        return byDisplay
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// A "get VCP feature" request, then its reply, checked: displays answer with a null
    /// message when busy, and some only after the request is sent twice.
    private func read(_ code: UInt8, _ service: CFTypeRef) -> (current: UInt16, max: UInt16)? {
        guard let readI2C else { return nil }
        for _ in 0..<2 {
            send([0x82, 0x01, code], service)
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if readI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0, reply[4] == code,
               reply[0..<10].reduce(0x50, ^) == reply[10] {
                return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
            }
            usleep(40_000)
        }
        return nil
    }

    private func write(_ code: UInt8, _ value: UInt16, _ service: CFTypeRef) -> Bool {
        send([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xff)], service)
    }

    /// A DDC/CI message with its checksum, sent twice (some displays miss the first).
    @discardableResult
    private func send(_ message: [UInt8], _ service: CFTypeRef) -> Bool {
        guard let writeI2C else { return false }
        var packet = message + [message.reduce(0x6E ^ 0x51, ^)]
        var ok = false
        for _ in 0..<2 {
            ok = writeI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess || ok
            usleep(10_000)
        }
        return ok
    }
}
