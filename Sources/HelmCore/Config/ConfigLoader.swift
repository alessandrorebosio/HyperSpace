import Foundation
import TOMLDecoder

public struct ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let message: String

    public var description: String { "\(path): \(message)" }
}

public enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/helm/helm.toml`, falling back to `~/.config/helm/helm.toml`.
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "helm/helm.toml")
    }

    /// Loads the config. A missing file is not an error: it means every feature is off.
    public static func load(from url: URL = defaultURL) -> Result<Config, ConfigError> {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return .success(Config())
        } catch {
            return .failure(ConfigError(path: url.path, message: error.localizedDescription))
        }
        return parse(text, path: url.path)
    }

    public static func parse(_ text: String, path: String = "helm.toml") -> Result<Config, ConfigError> {
        do {
            let config = try TOMLDecoder().decode(Config.self, from: text)
            _ = try InputPlan(config) // validates key names, combos and mouse inputs
            return .success(config)
        } catch let error as ConfigError {
            return .failure(ConfigError(path: path, message: error.message))
        } catch let error as DecodingError {
            return .failure(ConfigError(path: path, message: describe(error)))
        } catch {
            return .failure(ConfigError(path: path, message: "\(error)"))
        }
    }

    /// Writes a commented starter config if none exists yet. Returns the config URL.
    @discardableResult
    public static func createTemplateIfMissing(at url: URL = defaultURL) throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return url }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try template.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Turns a DecodingError into "keyboard.capslock.alone: <reason>".
    static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            keys.isEmpty ? "(top level)" : keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case let .typeMismatch(type, ctx):
            return "\(path(ctx.codingPath)): expected \(typeName(type))"
        case let .valueNotFound(type, ctx):
            return "\(path(ctx.codingPath)): missing \(typeName(type))"
        case let .keyNotFound(key, ctx):
            return "\(path(ctx.codingPath + [key])): required key is missing"
        case let .dataCorrupted(ctx):
            return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Int.Type: "an integer"
        case is Bool.Type: "true or false"
        default: "\(type)".contains("Dictionary") ? "a table" : "\(type)".contains("Array") ? "an array" : "\(type)"
        }
    }

    public static let template = """
    # Helm configuration. Saved changes are applied immediately.
    # Remapped keys and buttons only do what is mapped here; everything else is untouched.

    # ── Keyboard ─────────────────────────────────────────────
    # Once configured, Caps Lock no longer toggles caps lock.
    # [keyboard.capslock]
    # alone = "none"              # action when tapped alone, e.g. "escape"
    #
    # [keyboard.capslock.map]     # Caps + key; unlisted keys behave normally
    # h = "left_arrow"
    # j = "down_arrow"
    # k = "up_arrow"
    # l = "right_arrow"

    # ── Mouse ────────────────────────────────────────────────
    # [mouse.buttons]             # button2 = middle, button3 = back, button4 = forward
    # button3 = "navigate.back"
    # button4 = "navigate.forward"
    #
    # [[mouse.app]]               # per-app exceptions
    # bundle_id = "com.google.Chrome"
    # buttons = { button3 = "passthrough", button4 = "passthrough" }
    #
    # [mouse.scroll]              # wheel only; trackpads are never touched
    # reverse = true
    # linear = true
    # lines = 3

    # ── Window manager ───────────────────────────────────────
    # [wm]
    # enabled = true

    """
}
