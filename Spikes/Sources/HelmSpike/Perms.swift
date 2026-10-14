import ApplicationServices
import CoreGraphics
import IOKit.hid

enum Perms {
    static func run() {
        print("Accessibility      AXIsProcessTrusted          = \(AXIsProcessTrusted())")
        print("Post events        CGPreflightPostEventAccess  = \(CGPreflightPostEventAccess())")
        print("Listen events      CGPreflightListenEventAccess= \(CGPreflightListenEventAccess())")
        print("HID listen         IOHIDCheckAccess            = \(accessName(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))")
        print("HID post           IOHIDCheckAccess            = \(accessName(IOHIDCheckAccess(kIOHIDRequestTypePostEvent)))")
        print("(TCC checks the *responsible* app: the terminal or app that launched this binary)")
    }

    static func accessName(_ a: IOHIDAccessType) -> String {
        switch a {
        case kIOHIDAccessTypeGranted: "granted"
        case kIOHIDAccessTypeDenied: "denied"
        case kIOHIDAccessTypeUnknown: "unknown (never asked)"
        default: "\(a.rawValue)"
        }
    }
}
