import CoreGraphics
import Foundation
import IOKit

/// The input source an external display shows (DDC/CI VCP 0x60), read over the display's
/// I²C channel. A display switched to another computer often stays connected to macOS, so
/// this is the only way to tell. Apple silicon only (`IOAVService`, a private API looked up
/// at run time): elsewhere nothing is read.
final class DDC: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) } // RTLD_DEFAULT
    }

    private let create = symbol("IOAVServiceCreateWithService", as: Create.self)
    private let readI2C = symbol("IOAVServiceReadI2C", as: Transfer.self)
    private let writeI2C = symbol("IOAVServiceWriteI2C", as: Transfer.self)
    /// Reads take ~70 ms each: never on the main thread, one display at a time.
    private let queue = DispatchQueue(label: "hyperspace.wm.ddc", qos: .utility)
    /// The AV service of each display, found again only when the displays change.
    private var services: (displays: [CGDirectDisplayID], byDisplay: [CGDirectDisplayID: CFTypeRef]) = ([], [:])

    /// The input of each display that answers, by display id; the built-in one never does.
    func inputs(of displays: [CGDirectDisplayID], _ completion: @escaping @MainActor ([CGDirectDisplayID: UInt8]) -> Void) {
        queue.async { [self] in
            var inputs: [CGDirectDisplayID: UInt8] = [:]
            if create != nil, readI2C != nil, writeI2C != nil {
                let external = displays.filter { CGDisplayIsBuiltin($0) == 0 }.sorted()
                if services.displays != external { services = (external, findServices(external)) }
                for (display, service) in services.byDisplay {
                    if let input = readInput(service) { inputs[display] = input }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(inputs) } }
        }
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
            var name = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &name)
            switch String(cString: name) {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                let attributes = property(entry, "DisplayAttributes") as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                func number(_ key: String) -> UInt32? { (product?[key] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.uint64Value) } }
                lastEDID = number("LegacyManufacturerID").map { ($0, number("ProductID") ?? 0, number("SerialNumber") ?? 0) }
            case "DCPAVServiceProxy":
                guard property(entry, "Location") as? String == "External",
                      let service = create?(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append((lastEDID, service))
                lastEDID = nil
            default:
                break
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

    /// A "get VCP feature" request for 0x60, then its reply, checked: displays answer with
    /// a null message when busy, and some only after the request is sent twice.
    private func readInput(_ service: CFTypeRef) -> UInt8? {
        guard let readI2C, let writeI2C else { return nil }
        for _ in 0..<2 {
            var request: [UInt8] = [0x82, 0x01, 0x60, 0]
            request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
            for _ in 0..<2 {
                _ = writeI2C(service, 0x37, 0x51, &request, UInt32(request.count))
                usleep(10_000)
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if readI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0, reply[4] == 0x60,
               reply[0..<10].reduce(0x50, ^) == reply[10] {
                // The value's low byte: some displays (Dell) put garbage in the high one.
                return reply[9]
            }
            usleep(40_000)
        }
        return nil
    }
}
