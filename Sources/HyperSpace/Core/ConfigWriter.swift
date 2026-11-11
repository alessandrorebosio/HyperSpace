import Foundation

/// Edits `config.json` in place for the settings UI: only the touched keys
/// change, and the file stays hand-readable (stable key order, one line per
/// binding/remap). The ConfigStore watcher picks the write up and applies it.
enum ConfigWriter {
    static func read() -> [String: Any] {
        parse(try? Data(contentsOf: ConfigStore.url))
    }

    /// The file, or nil when it exists but does not parse (the settings keep what they show).
    static func readIfValid() -> [String: Any]? {
        guard let data = try? Data(contentsOf: ConfigStore.url),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// One top-level object of `root` ("keyboard", "mouse"…), empty when missing.
    static func section(_ key: String, of root: [String: Any]) -> [String: Any] {
        root[key] as? [String: Any] ?? [:]
    }

    /// Edits one top-level object of `root` in place, creating it when missing.
    static func edit(_ root: inout [String: Any], section key: String, _ change: (inout [String: Any]) -> Void) {
        var section = root[key] as? [String: Any] ?? [:]
        change(&section)
        root[key] = section
    }

    /// `save` for a change to a single top-level object.
    static func save(section key: String, _ change: (inout [String: Any]) -> Void) -> String? {
        save { edit(&$0, section: key, change) }
    }

    private static func parse(_ data: Data?) -> [String: Any] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }

    /// Refusal to edit a file that exists but is not a JSON object: starting from an empty
    /// one would replace everything the user wrote with the one change.
    struct SyntaxError: LocalizedError {
        var errorDescription: String? { "config.json has a syntax error: fix it before changing settings" }
    }

    /// Reads `url`, applies `change` and writes the result, unless nothing changed.
    /// Throws `SyntaxError`, without writing, when the file is there but does not parse.
    static func update(_ url: URL = ConfigStore.url, _ change: (inout [String: Any]) -> Void) throws {
        // A linked config (dotfiles) is edited where it lives: an atomic write to the link
        // itself would replace it with a regular file.
        let url = url.resolvingSymlinksInPath()
        // Read once: parsed to edit, and compared with what would be written.
        let current = try? Data(contentsOf: url)
        var root: [String: Any] = [:]
        if let current, !String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: current) as? [String: Any] else {
                throw SyntaxError()
            }
            root = parsed
        }
        change(&root)
        let text = text(for: root)
        // Nothing changed: no write, so no reload of the whole config.
        if let current, String(data: current, encoding: .utf8) == text { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file's text for `root` (apart from the write, what `update` saves).
    static func text(for root: [String: Any]) -> String {
        format(root, depth: 0) + "\n"
    }

    /// `update` for the settings pages: the error message, or nil when saved.
    static func save(_ change: (inout [String: Any]) -> Void) -> String? {
        do {
            try update(ConfigStore.url, change)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let keyOrder = [
        "keyboard", "mouse", "trackpad", "tiling",
        "hyperKey", "remap", "bindings",
        "keys", "from", "to", "button", "modifiers", "action",
        "reverseScroll", "dragModifier", "buttons",
        "edgeSliders", "leftEdge", "rightEdge",
        "enabled", "layout", "gap", "padding", "masterRatio", "accordionPadding", "mouseFollowsFocus", "scratchpad", "floating", "floatingWindows", "workspaces", "assign",
        "name", "switch", "move", "display", "app", "title", "workspace",
    ]

    private static func rank(_ key: String, depth: Int) -> Int {
        // Inside a remap rule "keyboard" is the target and reads best last.
        if key == "keyboard" && depth > 0 { return 999 }
        return keyOrder.firstIndex(of: key) ?? 500
    }

    private static func sortedKeys(_ dict: [String: Any], depth: Int) -> [String] {
        dict.keys.sorted { (rank($0, depth: depth), $0) < (rank($1, depth: depth), $1) }
    }

    private static func isScalar(_ value: Any) -> Bool {
        !(value is [Any]) && !(value is [String: Any])
    }

    private static func format(_ value: Any, depth: Int, inArray: Bool = false) -> String {
        let pad = String(repeating: "  ", count: depth)
        let inner = String(repeating: "  ", count: depth + 1)

        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            let keys = sortedKeys(dict, depth: depth)
            // Flat objects (a binding, a remap rule) stay on one line.
            if inArray, dict.values.allSatisfy(isScalar) {
                return "{ " + keys.map { "\(scalar($0)): \(scalar(dict[$0]!))" }.joined(separator: ", ") + " }"
            }
            let body = keys.map { "\(inner)\(scalar($0)): \(format(dict[$0]!, depth: depth + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(pad)}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            let body = array.map { "\(inner)\(format($0, depth: depth + 1, inArray: true))" }
            return "[\n" + body.joined(separator: ",\n") + "\n\(pad)]"
        }
        return scalar(value)
    }

    private static func scalar(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let string = value as? String,
           let data = try? JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes]),
           let json = String(data: data, encoding: .utf8) {
            return String(json.dropFirst().dropLast())
        }
        return "null"
    }
}
