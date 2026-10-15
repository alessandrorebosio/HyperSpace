/// What a remapped key or mouse input does.
///
/// In TOML an action is either a string or an inline table:
/// ```toml
/// h = "arrow.left"          # key or combo, e.g. "cmd-shift-k"
/// m = "volume.mute"         # a named action, e.g. navigate.back, mission.control
/// q = "none"                # swallow the input
/// x = "passthrough"         # keep the original behavior
/// t = { shell = "open -a Terminal" }
/// "1" = { wm = "workspace 1" }
/// d = { scroll = "down", lines = 5 }   # or pixels = 40
/// ```
public enum Action: Sendable, Equatable {
    case none
    case passthrough
    /// A key, a combo or a named action (e.g. `navigate.back`). Resolved by the plans.
    case keys(String)
    case shell(String)
    case wm(String)
    case scroll(String, ScrollAmount)
}

public enum ScrollAmount: Sendable, Equatable {
    case lines(Int), pixels(Int)
}

extension Action: Decodable {
    private enum TableKey: String, CodingKey, CaseIterable {
        case shell, wm, scroll, lines, pixels
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self = try Action(parsing: text, codingPath: decoder.codingPath)
            return
        }
        let table = try decoder.table(TableKey.self)
        func fail(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        let shell = try table.decodeIfPresent(String.self, forKey: .shell)
        let wm = try table.decodeIfPresent(String.self, forKey: .wm)
        let scroll = try table.decodeIfPresent(String.self, forKey: .scroll)
        let lines = try table.decodeIfPresent(Int.self, forKey: .lines)
        let pixels = try table.decodeIfPresent(Int.self, forKey: .pixels)
        guard [shell, wm, scroll].compactMap({ $0 }).count == 1 else {
            throw fail("an action table needs exactly one of `shell`, `wm` or `scroll`")
        }
        guard scroll != nil || (lines == nil && pixels == nil) else { throw fail("`lines` and `pixels` go with `scroll`") }
        guard lines == nil || pixels == nil else { throw fail("use either `lines` or `pixels`") }
        if let shell { self = .shell(shell) }
        else if let wm { self = .wm(wm) }
        else { self = .scroll(scroll!, pixels.map(ScrollAmount.pixels) ?? .lines(lines ?? 3)) }
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
