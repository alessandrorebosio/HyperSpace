import AppKit
import SwiftUI

/// Debug aid: `HyperSpace --render-settings <folder>` draws every page of the settings window,
/// light and dark, at two window sizes, saves the PNGs in the folder and quits.
///
/// Nothing of the app runs: no event tap, no remapping, no tiling, no menu bar item. The models
/// only read the config; nothing is written and no key or button capture is started.
///
/// With `HYPERSPACE_SNAPSHOT_SCREENCAPTURE=1` the window is shown on screen and photographed with
/// `screencapture` instead of drawn offscreen: slower and it needs Screen Recording, but it also
/// works where offscreen drawing comes out blank (the CI runners: no Liquid Glass, no SwiftUI
/// content in `cacheDisplay`).
enum SettingsSnapshot {
    private static let flag = "--render-settings"
    private static let useScreencapture = ProcessInfo.processInfo.environment["HYPERSPACE_SNAPSHOT_SCREENCAPTURE"] == "1"
    private static let sizes = [SettingsWindowController.minimumSize, NSSize(width: 900, height: 640)]
    private static let scale = 2

    /// The folder given after the flag, when the app was started to render the pages.
    static func folder(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        return next < arguments.endIndex ? arguments[next] : "."
    }

    /// Renders everything and returns the process exit code.
    static func render(into folder: String) -> Int32 {
        let directory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("Cannot create \(directory.path): \(error.localizedDescription)\n", stderr)
            return 1
        }

        // The models, built the way the settings window builds them, with nothing behind them.
        let windowManager = WindowManager()
        let eventTap = EventTap(drag: DragController(windowManager: windowManager)) { _ in }
        let keyboard = RemapModel(remapper: KeyboardRemapper(), eventTap: eventTap)
        let mouse = MouseModel(eventTap: eventTap)
        let tiling = TilingModel(eventTap: eventTap)
        let general = GeneralModel(actions: GeneralModel.Actions(openConfig: {}, problem: { nil }))

        var failures = 0
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for size in sizes {
                for page in SettingsNavigation.Page.allCases {
                    // A new window for every picture, born at its final size and page: no resize
                    // animation or scroll position left over from the previous one.
                    let navigation = SettingsNavigation()
                    navigation.page = page
                    let root = SettingsRoot(navigation: navigation, keyboard: keyboard, mouse: mouse, tiling: tiling, general: general)
                    let window = makeWindow(root, size: size, appearance: NSAppearance(named: appearance))
                    settle(window, seconds: 0.8)
                    let name = "\(page.fileName)-\(appearanceName)-\(Int(size.width))x\(Int(size.height)).png"
                    let url = directory.appendingPathComponent(name)
                    if let error = useScreencapture ? capture(window, to: url) : save(window, to: url) {
                        fputs("\(name): \(error)\n", stderr)
                        failures += 1
                    } else {
                        print(name)
                    }
                    window.orderOut(nil)
                    window.contentViewController = nil
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// The settings window as the app builds it, invisible, fully on screen.
    private static func makeWindow(_ root: SettingsRoot, size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let window = SettingsWindowController.makeWindow(root, size: size)
        window.appearance = appearance
        // Inside the visible area of the screen, so AppKit has no reason to move or clip it.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 40))
        // Invisible (unless it is photographed) and untouchable, but key and active, so the sidebar
        // draws like a live one.
        window.alphaValue = useScreencapture ? 1 : 0
        window.ignoresMouseEvents = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// A few turns of the run loop so SwiftUI lays the page out and the images load.
    private static func settle(_ window: NSWindow, seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// The window's content view drawn into a bitmap at `scale`, written as PNG. AppKit controls
    /// (Toggle, Picker, Slider) are drawn too, which `ImageRenderer` cannot do.
    private static func save(_ window: NSWindow, to url: URL) -> String? {
        guard let view = window.contentView else { return "no content view" }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return "cannot create the bitmap"
        }
        // Same size in points, more pixels: the drawing is scaled up, so the text stays sharp.
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "cannot encode the PNG" }
        do {
            try data.write(to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension SettingsSnapshot {
    /// The window as the window server shows it, without its shadow, written as PNG.
    fileprivate static func capture(_ window: NSWindow, to url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        if process.terminationStatus != 0 { return "screencapture exited with \(process.terminationStatus)" }
        return FileManager.default.fileExists(atPath: url.path) ? nil : "screencapture wrote nothing"
    }
}

extension SettingsNavigation.Page {
    /// Used in the names of the screenshots.
    fileprivate var fileName: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "mouse"
        case .tiling: return "tiling"
        case .workspaces: return "workspaces"
        case .windowRules: return "window-rules"
        case .shortcuts: return "shortcuts"
        case .settings: return "general"
        }
    }
}
