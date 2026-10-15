/// What a remapped key or mouse input does, as written in the config. Plans compile it into
/// an `Output` after checking names.
///
/// In TOML an action is either a string or an inline table:
/// ```toml
/// h = "arrow.left"                        # key or combo, e.g. "cmd-shift-k"
/// m = "volume.mute"                       # a named action (see SystemAction)
/// q = "none"                              # swallow the input
/// x = "passthrough"                       # keep the original behavior
/// t = { shell = "open -a Terminal" }      # run a shell command
/// s = { app = "Safari" }                  # open or focus an app (name or bundle id)
/// e = { text = "me@example.com" }         # type text, whatever the keyboard layout
/// c = { sequence = ["cmd-c", "cmd-tab", "cmd-v"] }   # actions one after another
/// d = { scroll = "down", lines = 5 }      # or pixels = 40
/// "1" = { wm = "workspace 1" }
/// u = { action = "volume.up", repeat = true }        # repeats while held
/// l = { action = "click.left", hold = true }         # pressed while held (drag)
/// ```
public indirect enum Action: Sendable, Equatable {
    case none
    case passthrough
    /// A key, a combo or a named action (e.g. `navigate.back`). Resolved by the plans.
    case keys(String)
    case shell(String)
    case wm(String)
    case app(String)
    case text(String)
    case sequence([Action])
    case scroll(String, ScrollAmount)
    /// Performed again at the key repeat rate while the input is held.
    case repeating(Action)
    /// Pressed when the input goes down, released when it goes up.
    case held(Action)
}

public enum ScrollAmount: Sendable, Equatable {
    case lines(Int), pixels(Int)
}

extension Action: Decodable {
    private enum TableKey: String, CodingKey, CaseIterable {
        case shell, wm, app, text, sequence, scroll, action, lines, pixels, `repeat`, hold
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self = try Action(parsing: text, codingPath: decoder.codingPath)
            return
        }
        let t = try decoder.table(TableKey.self)
        func fail(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        func string(_ key: TableKey) throws -> String? { try t.decodeIfPresent(String.self, forKey: key) }

        let kinds: [(TableKey, Action?)] = [
            (.shell, try string(.shell).map(Action.shell)),
            (.wm, try string(.wm).map(Action.wm)),
            (.app, try string(.app).map(Action.app)),
            (.text, try string(.text).map(Action.text)),
            (.sequence, try t.decodeIfPresent([Action].self, forKey: .sequence).map(Action.sequence)),
            (.action, try string(.action).map { try Action(parsing: $0, codingPath: decoder.codingPath) }),
            (.scroll, try string(.scroll).map { Action.scroll($0, .lines(3)) }),
        ]
        let present = kinds.compactMap(\.1)
        guard present.count == 1, var action = present.first else {
            throw fail("an action table needs exactly one of: \(kinds.map(\.0.stringValue).joined(separator: ", "))")
        }

        let lines = try t.decodeIfPresent(Int.self, forKey: .lines)
        let pixels = try t.decodeIfPresent(Int.self, forKey: .pixels)
        if case let .scroll(direction, _) = action {
            guard lines == nil || pixels == nil else { throw fail("use either `lines` or `pixels`") }
            action = .scroll(direction, pixels.map(ScrollAmount.pixels) ?? .lines(lines ?? 3))
        } else if lines != nil || pixels != nil {
            throw fail("`lines` and `pixels` go with `scroll`")
        }

        let repeats = try t.decode(.repeat, default: false)
        let holds = try t.decode(.hold, default: false)
        guard !(repeats && holds) else { throw fail("use either `repeat` or `hold`") }
        self = repeats ? .repeating(action) : holds ? .held(action) : action
    }

    init(parsing text: String, codingPath: [any CodingKey] = []) throws {
        switch text {
        case "none": self = .none
        case "passthrough": self = .passthrough
        case "":
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "empty action"))
        default: self = .keys(text)
        }
    }
}
