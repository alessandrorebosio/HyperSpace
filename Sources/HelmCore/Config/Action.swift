/// What a remapped key or mouse input does.
///
/// In TOML an action is either a string or an inline table:
/// ```toml
/// h = "left_arrow"          # key or combo, e.g. "cmd-shift-k"
/// q = "none"                # swallow the input
/// x = "passthrough"         # keep the original behavior
/// t = { shell = "open -a Terminal" }
/// "1" = { wm = "workspace 1" }
/// ```
public enum Action: Sendable, Equatable {
    case none
    case passthrough
    /// A key, a combo or a named action (e.g. `navigate.back`). Resolved by the engines.
    case keys(String)
    case shell(String)
    case wm(String)
}

extension Action: Decodable {
    private enum TableKey: String, CodingKey, CaseIterable {
        case shell, wm
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self = try Action(parsing: text, codingPath: decoder.codingPath)
            return
        }
        let table = try decoder.container(keyedBy: TableKey.self)
        try decoder.rejectUnknownKeys(TableKey.self)
        switch (try table.decodeIfPresent(String.self, forKey: .shell), try table.decodeIfPresent(String.self, forKey: .wm)) {
        case let (shell?, nil): self = .shell(shell)
        case let (nil, wm?): self = .wm(wm)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "an action table needs exactly one of `shell` or `wm`"
            ))
        }
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
