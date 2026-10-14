import Foundation

private let start = Date()

func log(_ message: String) {
    print(String(format: "%8.3f  ", Date().timeIntervalSince(start)) + message)
}

func hex<T: BinaryInteger>(_ v: T, width: Int = 2) -> String {
    "0x" + String(v, radix: 16, uppercase: true).leftPadded(to: width)
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String($0, radix: 16, uppercase: true).leftPadded(to: 2) }.joined(separator: " ")
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

func ioReturnName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess: "success"
    case kIOReturnNotPermitted: "not permitted"
    case kIOReturnNotPrivileged: "not privileged"
    case kIOReturnExclusiveAccess: "exclusive access"
    case kIOReturnNotOpen: "not open"
    default: hex(UInt32(bitPattern: r), width: 8)
    }
}
