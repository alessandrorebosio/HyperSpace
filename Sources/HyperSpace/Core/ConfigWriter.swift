import Foundation

/// Edits `config.json` in place for the settings UI: only the touched keys
/// change, and the file stays hand-readable (stable key order, one line per
/// binding/remap). The ConfigStore watcher picks the write up and applies it.
enum ConfigWriter {
    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: ConfigStore.url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }

    static func update(_ change: (inout [String: Any]) -> Void) throws {
        var root = read()
        change(&root)
        try (format(root, depth: 0) + "\n").write(to: ConfigStore.url, atomically: true, encoding: .utf8)
    }

    private static let keyOrder = [
        "keyboard", "mouse", "tiling",
        "hyperKey", "remap", "bindings",
        "keys", "from", "to", "button", "modifiers", "action",
        "reverseScroll", "dragModifier", "buttons",
        "enabled", "layout", "gap", "padding", "masterRatio", "floating", "workspaces",
        "name", "switch", "move",
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
