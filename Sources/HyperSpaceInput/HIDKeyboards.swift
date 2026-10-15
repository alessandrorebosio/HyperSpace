import Foundation
import IOKit
import IOKit.hidsystem

enum HIDKeyboards {
    /// Keyboard services of the HID event system. Karabiner's virtual keyboard replays
    /// already-remapped input, so it's left alone.
    static func all(_ client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return services.filter { service in
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 else { return false }
            let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? ""
            return !product.contains("Karabiner")
        }
    }
}
