import Foundation

/// Edits `config.json` in place for the settings UI: only the touched keys
/// change, and the file stays hand-readable (stable key order, one line per
/// binding/remap). The ConfigStore watcher picks the write up and applies it.
enum ConfigWriter {
    /// The file, `[:]` when it is missing or blank, or nil when it does not parse (the settings
    /// keep what they show).
    static func readIfValid() -> [String: Any]? {
        parseFile(ConfigStore.url).root
    }

    /// The file's bytes and what they hold: `[:]` when it is missing or blank, nil when it is
    /// not a JSON object or cannot be read (no permission, say: taking it for an empty one
    /// would replace everything in it with the next change). The one place the file is read
    /// and parsed for the settings.
    static func parseFile(_ url: URL) -> (data: Data?, root: [String: Any]?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (nil, isMissingFile(error) ? [:] : nil)
        }
        if isBlank(data) { return (data, [:]) }
        return (data, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Whether a file's bytes are only white space: an empty config, for `Config.load` too.
    static func isBlank(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether reading failed because nothing is there, rather than something unreadable.
    static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
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

    /// Refusal to edit a file that exists but is not a JSON object: starting from an empty
    /// one would replace everything the user wrote with the one change.
    struct SyntaxError: LocalizedError {
        static let message = "config.json has a syntax error: fix it before changing settings"
        var errorDescription: String? { Self.message }
    }

    /// Refusal to edit a file that is there but cannot be read, for the same reason.
    struct UnreadableError: LocalizedError {
        var errorDescription: String? { "config.json cannot be read: check its permissions before changing settings" }
    }

    /// Reads `url`, applies `change` and writes the result, unless nothing changed.
    /// Throws `SyntaxError` or `UnreadableError`, without writing, when the file is there but
    /// does not parse or cannot be read.
    static func update(_ url: URL = ConfigStore.url, _ change: (inout [String: Any]) -> Void) throws {
        // A linked config (dotfiles) is edited where it lives: an atomic write to the link
        // itself would replace it with a regular file.
        let url = url.resolvingSymlinksInPath().linkTarget
        // Read once: parsed to edit, and compared with what would be written.
        let (current, parsed) = parseFile(url)
        guard var root = parsed else {
            if current == nil { throw UnreadableError() }
            throw SyntaxError()
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
        "edgeSliders", "leftEdge", "rightEdge", "topEdge", "bottomEdge", "corners", "topLeft", "topRight", "bottomLeft", "bottomRight",
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
