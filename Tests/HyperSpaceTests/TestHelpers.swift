import CoreGraphics
import Foundation
@testable import HyperSpace

// Every test that touches a file does it under `withTemporaryDirectory`: none reads or writes
// the user's config (`~/.config/hyperspace`, `~/.hyperspace`), workspaces.json or UserDefaults,
// and none creates a Settings page model (they save to the real config).

func config(_ json: String) throws -> Config {
    try Config(JSONDecoder().decode(RawConfig.self, from: Data(json.utf8)))
}

/// The action bound to a shortcut, if any.
func action(_ config: Config, _ keys: String) throws -> Action? {
    let combo = try KeyCombo.parse(keys)
    let index = config.tap.keyTable[TapConfig.slot(Int(combo.keyCode), combo.modifiers)]
    return index >= 0 ? config.tap.actions[Int(index)] : nil
}

/// The message of the `ConfigError` `body` throws; nil when it throws nothing.
func configErrorMessage(_ body: () throws -> Any) -> String? {
    do {
        _ = try body()
        return nil
    } catch let error as ConfigError {
        return error.message
    } catch {
        return "not a ConfigError: \(error)"
    }
}

/// Whether the event tap's `mask` subscribes to `type`.
func maskHas(_ mask: CGEventMask, _ type: CGEventType) -> Bool {
    mask & (CGEventMask(1) << type.rawValue) != 0
}

/// Runs `body` with a new empty directory under the temporary directory, removed afterwards.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// `withTemporaryDirectory` for an async body.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

private func makeTemporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyperspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Waits, yielding the main actor (where the watchers and the schedulers run), until
/// `condition` holds or `timeout` seconds pass. The bound is generous: a slow machine only waits longer.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
}

/// A display whose frame starts at (`x`, `y`) in top-left coordinates. `menuBar` points are
/// taken off the top of its visible frame, as on the main display.
func makeScreen(_ id: CGDirectDisplayID = 1, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1000,
                height: CGFloat = 600, menuBar: CGFloat = 0, name: String = "") -> ScreenInfo {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    let visible = CGRect(x: x, y: y + menuBar, width: width, height: height - menuBar)
    return ScreenInfo(id: id, frame: frame, visible: visible, name: name)
}

/// The repository's root, found from this file's place in it.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
