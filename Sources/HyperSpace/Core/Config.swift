import CoreGraphics
import Foundation

struct ConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The JSON file as written by the user.
struct RawConfig: Decodable {
    struct Keyboard: Decodable {
        var hyperKey: String?
        var remap: [Remap]?
        var bindings: [Binding]?
    }
    struct Remap: Decodable {
        var from: String
        var to: String
        /// "all" (default), "builtin", "external" or part of a keyboard's product name.
        var keyboard: String?
    }
    struct Binding: Decodable {
        var keys: String
        var action: String
    }
    struct Mouse: Decodable {
        var reverseScroll: Bool?
        var dragModifier: String?
        var buttons: [Button]?
    }
    struct Button: Decodable {
        var button: Int
        var modifiers: String?
        var action: String
    }
    struct Tiling: Decodable {
        var enabled: Bool?
        var layout: String?
        var gap: Double?
        var padding: Double?
        var masterRatio: Double?
        var floating: [String]?
        var workspaces: [Workspace]?
    }
    struct Workspace: Decodable {
        var name: String?
        /// Shortcut that shows the workspace.
        var switchKeys: String?
        /// Shortcut that moves the focused window there.
        var move: String?

        enum CodingKeys: String, CodingKey {
            case name, move
            case switchKeys = "switch"
        }
    }

    var keyboard: Keyboard?
    var mouse: Mouse?
    var tiling: Tiling?
}

/// Lookup tables consumed by the event tap. Indexed by `slot(code, mods)`,
/// so matching an event is a single array read with no hashing or allocation.
struct TapConfig {
    static let keySlots = 128 << 4
    static let buttonSlots = 32 << 4

    var keyTable = [Int16](repeating: -1, count: keySlots)
    var buttonTable = [Int16](repeating: -1, count: buttonSlots)
    var actions: [Action] = []
    /// Carrier key code → index in `carriers` (-1 when the key is not a carrier).
    var carrierTable = [Int8](repeating: -1, count: 128)
    var carriers: [Carrier] = []
    var reverseScroll = false
    var dragModifier: Modifiers?
    /// Caps lock is remapped: keep the caps lock state off (see `CapsLock`).
    var suppressCapsLock = false

    static func slot(_ code: Int, _ mods: Modifiers) -> Int {
        code << 4 | Int(mods.rawValue)
    }

    mutating func bindKey(_ combo: KeyCombo, _ action: Action) {
        actions.append(action)
        keyTable[Self.slot(Int(combo.keyCode), combo.modifiers)] = Int16(actions.count - 1)
    }

    mutating func bindButton(_ button: Int, _ mods: Modifiers, _ action: Action) {
        actions.append(action)
        buttonTable[Self.slot(button, mods)] = Int16(actions.count - 1)
    }

    /// A key remapped (in HID) onto `keyCode` that the tap turns into a combination.
    struct Carrier {
        let modifiers: Modifiers
        /// Pressed together with the modifiers; nil for modifier-only combinations (held instead).
        let keyCode: UInt16?
    }

    mutating func addCarrier(keyCode: UInt16, _ carrier: Carrier) {
        carriers.append(carrier)
        carrierTable[Int(keyCode)] = Int8(carriers.count - 1)
    }

    /// Only subscribe to the event types that are actually used: an unused
    /// feature costs nothing, and with an empty config no tap is installed at all.
    var eventMask: CGEventMask {
        var mask: CGEventMask = 0
        func add(_ type: CGEventType) { mask |= CGEventMask(1) << type.rawValue }
        if !carriers.isEmpty || suppressCapsLock || keyTable.contains(where: { $0 >= 0 }) {
            add(.keyDown); add(.keyUp)
        }
        if suppressCapsLock {
            add(.flagsChanged)
        }
        if carriers.contains(where: { $0.keyCode == nil }) {
            // Held combination modifiers also apply to clicks (e.g. ⌃⌥⇧-click).
            add(.leftMouseDown); add(.leftMouseUp); add(.rightMouseDown); add(.rightMouseUp)
            add(.otherMouseDown); add(.otherMouseUp)
        }
        if buttonTable.contains(where: { $0 >= 0 }) {
            add(.otherMouseDown); add(.otherMouseUp)
        }
        if reverseScroll {
            add(.scrollWheel)
        }
        if dragModifier != nil {
            add(.leftMouseDown); add(.leftMouseDragged); add(.leftMouseUp)
            add(.rightMouseDown); add(.rightMouseDragged); add(.rightMouseUp)
        }
        return mask
    }
}

struct TilingConfig {
    var enabled = true
    var layout = LayoutKind.tall
    var gap: CGFloat = 8
    var padding: CGFloat = 8
    var masterRatio: CGFloat = 0.55
    var floating: Set<String> = []
    /// Workspace names; empty means a single implicit workspace.
    var workspaces: [String] = []
}

/// Validated, compiled configuration.
struct Config {
    var remaps: [RemapRule] = []
    var tap = TapConfig()
    var tiling = TilingConfig()

    static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        let raw: RawConfig
        do {
            raw = try JSONDecoder().decode(RawConfig.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw ConfigError("invalid JSON: \(context.underlyingError?.localizedDescription ?? context.debugDescription)")
        } catch {
            throw ConfigError("invalid config: \(error)")
        }
        return try Config(raw)
    }

    init(_ raw: RawConfig) throws {
        let keyboard = raw.keyboard

        // `hyperKey` is shorthand for a remap to "hyper" on every keyboard.
        var rawRemaps = keyboard?.remap ?? []
        if let name = keyboard?.hyperKey, !name.isEmpty {
            rawRemaps.insert(RawConfig.Remap(from: name, to: "hyper", keyboard: nil), at: 0)
        }
        let parsed = try rawRemaps.map { remap -> (from: UInt64, to: RemapTarget, target: KeyboardTarget) in
            guard let from = KeyCodes.lookup(remap.from)?.hidUsage else { throw ConfigError("unknown key '\(remap.from)' in remap") }
            return (from, try RemapTarget.parse(remap.to), KeyboardTarget(remap.keyboard))
        }

        var boundKeyCodes = Set<UInt16>()
        for binding in keyboard?.bindings ?? [] {
            let combo = try KeyCombo.parse(binding.keys)
            boundKeyCodes.insert(combo.keyCode)
            tap.bindKey(combo, try Action.parse(binding.action))
        }

        var usedHID = Set(parsed.map(\.from))
        for case let (_, .key(hid), _) in parsed { usedHID.insert(hid) }
        var pool = CarrierPool(excludingHID: usedHID, keyCodes: boundKeyCodes)
        for (from, to, target) in parsed {
            switch to {
            case .key(let hid):
                remaps.append(RemapRule(from: from, to: hid, target: target))
            case .combination(let mods, let keyCode, _):
                let (carrier, isNew) = try pool.carrier(for: "\(mods.rawValue)-\(keyCode.map(String.init) ?? "")")
                if isNew { tap.addCarrier(keyCode: carrier.keyCode!, .init(modifiers: mods, keyCode: keyCode)) }
                remaps.append(RemapRule(from: from, to: carrier.hidUsage!, target: target))
            }
        }
        tap.suppressCapsLock = remaps.contains { $0.from == KeyCodes.lookup("caps_lock")?.hidUsage }

        if let mouse = raw.mouse {
            tap.reverseScroll = mouse.reverseScroll ?? false
            if let drag = mouse.dragModifier, !drag.isEmpty {
                tap.dragModifier = try Modifiers.parse(drag)
            }
            for button in mouse.buttons ?? [] {
                // 0 and 1 are left/right click: remapping them would make the mouse unusable.
                guard (2..<32).contains(button.button) else {
                    throw ConfigError("mouse button must be between 2 and 31 (got \(button.button))")
                }
                tap.bindButton(button.button, try Modifiers.parse(button.modifiers ?? ""), try Action.parse(button.action))
            }
        }

        if let tiling = raw.tiling {
            self.tiling.enabled = tiling.enabled ?? true
            if let layout = tiling.layout {
                guard let kind = LayoutKind(rawValue: layout.lowercased()) else { throw ConfigError("unknown layout '\(layout)'") }
                self.tiling.layout = kind
            }
            self.tiling.gap = CGFloat(max(0, tiling.gap ?? 8))
            self.tiling.padding = CGFloat(max(0, tiling.padding ?? 8))
            self.tiling.masterRatio = CGFloat(min(0.9, max(0.1, tiling.masterRatio ?? 0.55)))
            self.tiling.floating = Set(tiling.floating ?? [])
            for (index, workspace) in (tiling.workspaces ?? []).enumerated() {
                self.tiling.workspaces.append(workspace.name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(index + 1)")
                if let keys = workspace.switchKeys, !keys.isEmpty { tap.bindKey(try KeyCombo.parse(keys), .workspace(index)) }
                if let keys = workspace.move, !keys.isEmpty { tap.bindKey(try KeyCombo.parse(keys), .moveToWorkspace(index)) }
            }
        }
    }
}
