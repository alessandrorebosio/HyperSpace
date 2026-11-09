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
    /// Sliders along the left and right edges of the trackpad.
    struct Trackpad: Decodable {
        var edgeSliders: Bool?
        var leftEdge: String?
        var rightEdge: String?
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
        var floatingWindows: [FloatingWindow]?
        var workspaces: [Workspace]?
        var assign: [Assignment]?
        var mouseFollowsFocus: Bool?
        var scratchpad: Scratchpad?
        var accordionPadding: Double?
    }
    /// Size of scratchpad windows, as fractions of the display.
    struct Scratchpad: Decodable {
        var width: Double?
        var height: Double?
    }
    /// Windows whose title contains `title`, of `app` (bundle id) or of any app.
    struct FloatingWindow: Decodable {
        var app: String?
        var title: String
    }
    /// Windows of `app` (bundle id) open in workspace `workspace` (name or number).
    struct Assignment: Decodable {
        var app: String
        var workspace: String
    }
    struct Workspace: Decodable {
        var name: String?
        /// Shortcut that shows the workspace.
        var switchKeys: String?
        /// Shortcut that moves the focused window there.
        var move: String?
        /// The display the workspace is pinned to: "main", a number (1 = main display, then
        /// left to right), or the monitor's name or UUID.
        var display: String?

        enum CodingKeys: String, CodingKey {
            case name, move, display
            case switchKeys = "switch"
        }
    }

    var keyboard: Keyboard?
    var mouse: Mouse?
    var trackpad: Trackpad?
    var tiling: Tiling?
}

/// Lookup tables consumed by the event tap. Indexed by `slot(code, mods)`,
/// so matching an event is a single array read with no hashing or allocation.
struct TapConfig: Equatable {
    static let defaultReverseScroll = false
    static let keySlots = 128 << 4
    static let buttonSlots = 32 << 4

    var keyTable = [Int16](repeating: -1, count: keySlots)
    var buttonTable = [Int16](repeating: -1, count: buttonSlots)
    var actions: [Action] = []
    /// Carrier key code → index in `carriers` (-1 when the key is not a carrier).
    var carrierTable = [Int8](repeating: -1, count: 128)
    var carriers: [Carrier] = []
    var reverseScroll = TapConfig.defaultReverseScroll
    var dragModifier: Modifiers?
    /// Caps lock is remapped: keep the caps lock state off (see `CapsLock`).
    var suppressCapsLock = false
    /// The trackpad edge sliders are on: pointer moves are watched, to hold the pointer still
    /// while a slider is in progress (`EventTap.setPointerHeld`).
    var holdsPointer = false

    static func slot(_ code: Int, _ mods: Modifiers) -> Int {
        code << 4 | Int(mods.rawValue)
    }

    mutating func bindKey(_ combo: KeyCombo, _ action: Action) {
        Self.bind(action, in: &keyTable, at: Self.slot(Int(combo.keyCode), combo.modifiers), actions: &actions)
    }

    mutating func bindButton(_ button: Int, _ mods: Modifiers, _ action: Action) {
        Self.bind(action, in: &buttonTable, at: Self.slot(button, mods), actions: &actions)
    }

    /// Puts `action` in a table slot. A slot already taken keeps its place in `actions` and
    /// gets the new action (the last binding wins) instead of leaving an action nobody reaches.
    private static func bind(_ action: Action, in table: inout [Int16], at slot: Int, actions: inout [Action]) {
        if table[slot] >= 0 {
            actions[Int(table[slot])] = action
        } else {
            actions.append(action)
            table[slot] = Int16(actions.count - 1)
        }
    }

    /// A key remapped (in HID) onto `keyCode` that the tap turns into a combination.
    struct Carrier: Equatable {
        let modifiers: Modifiers
        /// Pressed together with the modifiers; nil for modifier-only combinations (held instead).
        let keyCode: UInt16?
    }

    /// The same config with the key of every combination typed on the key `layout` gives it
    /// (a symbol such as "-" sits elsewhere on other layouts).
    func translated(_ layout: (UInt16) -> UInt16) -> TapConfig {
        var copy = self
        copy.carriers = carriers.map { Carrier(modifiers: $0.modifiers, keyCode: $0.keyCode.map(layout)) }
        return copy
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
        if holdsPointer {
            add(.mouseMoved)
        }
        if dragModifier != nil {
            add(.leftMouseDown); add(.leftMouseDragged); add(.leftMouseUp)
            add(.rightMouseDown); add(.rightMouseDragged); add(.rightMouseUp)
        }
        return mask
    }
}

struct TilingConfig {
    /// The defaults of every option, shared by the config parser and the settings pages.
    static let defaultEnabled = true
    static let defaultLayout = LayoutKind.columns
    static let defaultGap: CGFloat = 8
    static let defaultPadding: CGFloat = 8
    static let defaultMasterRatio: CGFloat = 0.55
    /// What the config accepts (and the settings sliders offer) for the gap and the padding.
    static let spacingRange: ClosedRange<CGFloat> = 0...64
    /// The share of the screen the master area takes.
    static let ratioRange: ClosedRange<CGFloat> = 0.1...0.9
    static let defaultMouseFollowsFocus = true
    static let defaultScratchpadSize = CGSize(width: 0.6, height: 0.7)
    static let defaultAccordionPadding: CGFloat = 30
    static let accordionPaddingRange: ClosedRange<CGFloat> = 0...200

    var enabled = TilingConfig.defaultEnabled
    var layout = TilingConfig.defaultLayout
    var gap = TilingConfig.defaultGap
    var padding = TilingConfig.defaultPadding
    var masterRatio = TilingConfig.defaultMasterRatio
    var floating: Set<String> = []
    var floatingWindows: [FloatingWindowRule] = []
    /// Workspace names; empty means a single implicit workspace.
    var workspaces: [String] = []
    /// Bundle id → workspace index for windows to open in.
    var assignments: [String: Int] = [:]
    /// Workspace index → the display it is pinned to (see `ScreenInfo.pinned`).
    var pins: [Int: String] = [:]
    /// Moving the focus to another display brings the pointer along.
    var mouseFollowsFocus = TilingConfig.defaultMouseFollowsFocus
    /// Scratchpad windows' size, as fractions of the display's visible area.
    var scratchpadSize = TilingConfig.defaultScratchpadSize
    /// Accordion layout: how much of the windows behind the focused one shows on each side.
    var accordionPadding = TilingConfig.defaultAccordionPadding
    /// Workspace index → the shortcut that shows it, as written in the config (the last one wins).
    var switchKeys: [Int: String] = [:]
}

/// Windows that float by title (a dialog, an app's own settings), of one app or any.
struct FloatingWindowRule: Hashable {
    var app: String?
    /// Case-insensitive substring of the window title.
    var title: String

    func matches(app bundleID: String?, title windowTitle: String?) -> Bool {
        guard app == nil || app == bundleID, let windowTitle, !title.isEmpty else { return false }
        return windowTitle.range(of: title, options: .caseInsensitive) != nil
    }
}

extension TilingConfig {
    /// A title rule as written in the file or typed in Settings: dropped when its title is
    /// empty; an empty app means any app.
    static func floatingRule(app: String?, title: String) -> FloatingWindowRule? {
        guard !title.isEmpty else { return nil }
        return FloatingWindowRule(app: app?.nilIfEmpty, title: title)
    }

    /// The name of a workspace: the one given, or its 1-based position when none (or empty).
    static func workspaceName(_ name: String?, at index: Int) -> String {
        name?.nilIfEmpty ?? "\(index + 1)"
    }

    /// Whether a window floats: its app is floating, or a title rule matches it.
    func floats(app bundleID: String?, title: String?) -> Bool {
        if let bundleID, floating.contains(bundleID) { return true }
        return floatingWindows.contains { $0.matches(app: bundleID, title: title) }
    }
}

extension String {
    /// nil for the empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension DispatchQueue {
    /// Runs `work` once after each of `delays` (seconds), for things that settle a moment later.
    func asyncAfter(delays: [TimeInterval], execute work: @escaping () -> Void) {
        for delay in delays { asyncAfter(deadline: .now() + delay, execute: work) }
    }
}

extension Comparable {
    /// `self` limited to `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

/// What sliding a finger along an edge of the trackpad changes.
enum EdgeAction: String, CaseIterable {
    case volume
    case brightness
    case none

    /// A name as written in the config, in any case.
    init?(configText text: String) { self.init(rawValue: text.lowercased()) }
}

/// The edge sliders of the trackpad: one finger slid up or down along the left or right edge.
struct TrackpadConfig: Equatable {
    static let defaultEdgeSliders = false
    static let defaultLeftEdge = EdgeAction.brightness
    static let defaultRightEdge = EdgeAction.volume

    var edgeSliders = TrackpadConfig.defaultEdgeSliders
    var leftEdge = TrackpadConfig.defaultLeftEdge
    var rightEdge = TrackpadConfig.defaultRightEdge

    /// Whether any edge does something: with nothing to do the trackpads are not watched.
    var isActive: Bool { edgeSliders && (leftEdge != .none || rightEdge != .none) }
}

/// Validated, compiled configuration.
struct Config {
    var remaps: [RemapRule] = []
    var tap = TapConfig()
    var tiling = TilingConfig()
    var trackpad = TrackpadConfig()

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

        // Shortcuts first: carrier keys for combinations must avoid every key they use.
        var boundKeyCodes = Set<UInt16>()
        func bind(_ keys: String, _ action: Action) throws {
            let combo = try KeyCombo.parse(keys)
            boundKeyCodes.insert(combo.keyCode)
            tap.bindKey(combo, action)
            if case .workspace(let index) = action { tiling.switchKeys[index] = keys }
        }
        for binding in keyboard?.bindings ?? [] {
            try bind(binding.keys, try Action.parse(binding.action))
        }
        if let tiling = raw.tiling {
            for (keys, action) in try parseTiling(tiling) { try bind(keys, action) }
        }
        if let mouse = raw.mouse {
            try parseMouse(mouse)
        }
        if let trackpad = raw.trackpad {
            try parseTrackpad(trackpad)
        }
        tap.holdsPointer = self.trackpad.isActive

        // `hyperKey` is shorthand for a remap to "hyper" on every keyboard.
        var rawRemaps = keyboard?.remap ?? []
        if let name = keyboard?.hyperKey, !name.isEmpty {
            rawRemaps.insert(RawConfig.Remap(from: name, to: "hyper", keyboard: nil), at: 0)
        }
        let parsed = try rawRemaps.map { remap -> (from: KeyInfo, to: RemapTarget, target: KeyboardTarget) in
            guard let from = KeyCodes.lookup(remap.from) else { throw ConfigError("unknown key '\(remap.from)' in remap") }
            return (from, try RemapTarget.parse(remap.to), KeyboardTarget(remap.keyboard))
        }

        // A carrier must not share its HID usage or its key code with any key the config
        // uses: the tap tells keys apart by key code, and some keys share one (`print_screen`
        // and F13, `scroll_lock` and F14, `pause` and F15).
        var usedHID = Set<UInt64>()
        var usedCodes = boundKeyCodes
        for item in parsed {
            usedHID.insert(item.from.hidUsage)
            if let code = item.from.keyCode { usedCodes.insert(code) }
            if case .key(let hid) = item.to {
                usedHID.insert(hid)
                if let code = KeyCodes.keyCode(forHID: hid) { usedCodes.insert(code) }
            }
        }
        var pool = CarrierPool(excludingHID: usedHID, keyCodes: usedCodes)
        for item in parsed {
            switch item.to {
            case .key(let hid):
                remaps.append(RemapRule(from: item.from.hidUsage, to: hid, target: item.target))
            case .combination(let mods, let keyCode, _):
                let (carrier, isNew) = try pool.carrier(for: "\(mods.rawValue)-\(keyCode.map(String.init) ?? "")")
                if isNew { tap.addCarrier(keyCode: carrier.keyCode!, .init(modifiers: mods, keyCode: keyCode)) }
                remaps.append(RemapRule(from: item.from.hidUsage, to: carrier.hidUsage, target: item.target))
            }
        }
        let capsLock = KeyCodes.lookup("caps_lock")?.hidUsage
        tap.suppressCapsLock = remaps.contains { $0.from == capsLock }
    }

    private mutating func parseTrackpad(_ raw: RawConfig.Trackpad) throws {
        func edge(_ text: String?, _ fallback: EdgeAction, _ key: String) throws -> EdgeAction {
            guard let text, !text.isEmpty else { return fallback }
            guard let action = EdgeAction(configText: text) else {
                throw ConfigError("\(key) must be volume, brightness or none (got '\(text)')")
            }
            return action
        }
        trackpad.edgeSliders = raw.edgeSliders ?? TrackpadConfig.defaultEdgeSliders
        trackpad.leftEdge = try edge(raw.leftEdge, TrackpadConfig.defaultLeftEdge, "leftEdge")
        trackpad.rightEdge = try edge(raw.rightEdge, TrackpadConfig.defaultRightEdge, "rightEdge")
    }

    private mutating func parseMouse(_ mouse: RawConfig.Mouse) throws {
        tap.reverseScroll = mouse.reverseScroll ?? TapConfig.defaultReverseScroll
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

    /// Fills `tiling` and returns the workspace shortcuts to bind.
    private mutating func parseTiling(_ raw: RawConfig.Tiling) throws -> [(String, Action)] {
        var shortcuts: [(String, Action)] = []
        typealias Defaults = TilingConfig
        func clamped(_ value: Double?, to range: ClosedRange<CGFloat>, _ fallback: CGFloat) -> CGFloat {
            value.map { CGFloat($0).clamped(to: range) } ?? fallback
        }
        tiling.enabled = raw.enabled ?? Defaults.defaultEnabled
        if let layout = raw.layout {
            guard let kind = LayoutKind(configText: layout) else { throw ConfigError("unknown layout '\(layout)'") }
            tiling.layout = kind
        }
        tiling.gap = clamped(raw.gap, to: Defaults.spacingRange, Defaults.defaultGap)
        tiling.padding = clamped(raw.padding, to: Defaults.spacingRange, Defaults.defaultPadding)
        tiling.masterRatio = clamped(raw.masterRatio, to: Defaults.ratioRange, Defaults.defaultMasterRatio)
        tiling.floating = Set(raw.floating ?? [])
        tiling.floatingWindows = (raw.floatingWindows ?? []).compactMap { TilingConfig.floatingRule(app: $0.app, title: $0.title) }
        tiling.mouseFollowsFocus = raw.mouseFollowsFocus ?? Defaults.defaultMouseFollowsFocus
        tiling.accordionPadding = clamped(raw.accordionPadding, to: Defaults.accordionPaddingRange, Defaults.defaultAccordionPadding)
        tiling.scratchpadSize = CGSize(width: clamped(raw.scratchpad?.width, to: 0.2...1, Defaults.defaultScratchpadSize.width),
                                       height: clamped(raw.scratchpad?.height, to: 0.2...1, Defaults.defaultScratchpadSize.height))
        for (index, workspace) in (raw.workspaces ?? []).enumerated() {
            tiling.workspaces.append(TilingConfig.workspaceName(workspace.name, at: index))
            if let keys = workspace.switchKeys, !keys.isEmpty { shortcuts.append((keys, .workspace(index))) }
            if let keys = workspace.move, !keys.isEmpty { shortcuts.append((keys, .moveToWorkspace(index))) }
            if let display = workspace.display?.trimmingCharacters(in: .whitespaces), !display.isEmpty {
                tiling.pins[index] = display
            }
        }
        let names = tiling.workspaces
        for rule in raw.assign ?? [] {
            guard let index = names.firstIndex(of: rule.workspace)
                    ?? Int(rule.workspace).map({ $0 - 1 }).flatMap({ names.indices.contains($0) ? $0 : nil }) else {
                throw ConfigError("app rule for \(rule.app): no workspace named '\(rule.workspace)'")
            }
            tiling.assignments[rule.app] = index
        }
        return shortcuts
    }
}
