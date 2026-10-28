import AppKit
import IOKit
import IOKit.hidsystem

/// Which keyboards a remap rule applies to.
enum KeyboardTarget: Equatable {
    case all
    case builtIn
    case external
    /// Case-insensitive substring of the keyboard's product name ("Magic Keyboard", "USB Receiver").
    case product(String)

    init(_ text: String?) {
        switch text?.lowercased() {
        case nil, "", "all": self = .all
        case "builtin", "built-in", "internal": self = .builtIn
        case "external": self = .external
        default: self = .product(text!)
        }
    }

    /// When several rules remap the same key on a keyboard, the most specific one wins.
    var specificity: Int {
        switch self {
        case .all: return 0
        case .builtIn, .external: return 1
        case .product: return 2
        }
    }

    func matches(product: String, builtIn: Bool) -> Bool {
        switch self {
        case .all: return true
        case .builtIn: return builtIn
        case .external: return !builtIn
        case .product(let name): return product.range(of: name, options: .caseInsensitive) != nil
        }
    }
}

struct RemapRule: Equatable {
    let from: UInt64
    let to: UInt64
    let target: KeyboardTarget
}

/// Key remapping inside the HID event system, per keyboard.
///
/// Mappings are written as the `UserKeyMapping` property of each keyboard's HID
/// service (what `hidutil` does), so they run in the kernel/HID layer before any
/// app sees the key: zero CPU at runtime, every key including caps lock and fn,
/// and no permission at all. New keyboards (USB, Bluetooth, reconnects) are
/// picked up from IOKit match notifications; nothing is polled.
final class KeyboardRemapper {
    private static let mappingKey = "UserKeyMapping" as CFString

    struct Keyboard: Hashable {
        let product: String
        let builtIn: Bool
    }

    /// Called after a keyboard is connected or the Mac wakes.
    var onKeyboardsChanged: (() -> Void)?

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var rules: [RemapRule] = []
    /// While set, every keyboard sends its physical keys (used to capture keys in the editor).
    private var suspended = false
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?

    init() {
        watchKeyboards()
    }

    func apply(_ rules: [RemapRule]) {
        self.rules = rules
        sync()
    }

    /// Restores every keyboard to its default layout (on quit).
    func reset() {
        rules = []
        sync()
    }

    func suspend() {
        suspended = true
        sync()
    }

    func resume() {
        suspended = false
        sync()
    }

    /// Connected keyboards, built-in first, without duplicates (one keyboard may expose several services).
    func connectedKeyboards() -> [Keyboard] {
        var seen = Set<Keyboard>()
        return keyboardServices()
            .map { Self.describe($0) }
            .filter { seen.insert($0).inserted }
            .sorted { ($0.builtIn ? 0 : 1, $0.product) < ($1.builtIn ? 0 : 1, $1.product) }
    }

    private func keyboardServices() -> [IOHIDServiceClient] {
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
    }

    private static func describe(_ service: IOHIDServiceClient) -> Keyboard {
        Keyboard(
            product: IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? "",
            builtIn: (IOHIDServiceClientCopyProperty(service, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue ?? false
        )
    }

    /// Brings every connected keyboard in line with the rules, writing only where needed.
    private func sync() {
        for service in keyboardServices() {
            let keyboard = Self.describe(service)
            let product = keyboard.product
            let desired = suspended ? NSArray() : Self.mapping(rules, product: product, builtIn: keyboard.builtIn)
            let current = IOHIDServiceClientCopyProperty(service, Self.mappingKey) as? NSArray ?? []
            guard !current.isEqual(desired) else { continue }
            IOHIDServiceClientSetProperty(service, Self.mappingKey, desired as CFArray)
            log.info("keyboard '\(product, privacy: .public)': \(desired.count) mapping(s)")
        }
    }

    private static func mapping(_ rules: [RemapRule], product: String, builtIn: Bool) -> NSArray {
        var bySource: [UInt64: (specificity: Int, to: UInt64)] = [:]
        for rule in rules where rule.target.matches(product: product, builtIn: builtIn) {
            if let existing = bySource[rule.from], existing.specificity > rule.target.specificity { continue }
            bySource[rule.from] = (rule.target.specificity, rule.to)
        }
        return bySource.keys.sorted().map { from in
            [
                "HIDKeyboardModifierMappingSrc": NSNumber(value: from),
                "HIDKeyboardModifierMappingDst": NSNumber(value: bySource[from]!.to),
            ] as NSDictionary
        } as NSArray
    }

    private func watchKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
            { refcon, iterator in
                KeyboardRemapper.drain(iterator)
                guard let refcon else { return }
                Unmanaged<KeyboardRemapper>.fromOpaque(refcon).takeUnretainedValue().keyboardsChanged()
            },
            Unmanaged.passUnretained(self).toOpaque(), &iterator
        )
        // The notification only arms once the iterator has been drained.
        if result == KERN_SUCCESS { Self.drain(iterator) }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.keyboardsChanged() }
    }

    /// The HID service client shows up shortly after the IOKit registry entry.
    private func keyboardsChanged() {
        for delay in [0.3, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sync()
                self?.onKeyboardsChanged?()
            }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
