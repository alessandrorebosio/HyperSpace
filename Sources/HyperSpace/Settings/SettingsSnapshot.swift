import AppKit
import SwiftUI

/// Debug aid: `HyperSpace --render-settings <folder>` draws every page of the settings window,
/// light and dark, at two window sizes, saves the PNGs in the folder and quits.
///
/// Nothing of the app runs: no event tap, no remapping, no tiling, no menu bar item. The models
/// only read the config; nothing is written and no key or button capture is started.
enum SettingsSnapshot {
    private static let flag = "--render-settings"
    private static let sizes = [NSSize(width: 720, height: 460), NSSize(width: 900, height: 640)]
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
        let navigation = SettingsNavigation()
        let root = SettingsRoot(
            navigation: navigation,
            keyboard: RemapModel(remapper: KeyboardRemapper(), eventTap: eventTap),
            mouse: MouseModel(eventTap: eventTap),
            tiling: TilingModel(eventTap: eventTap),
            general: GeneralModel(actions: GeneralModel.Actions(openConfig: {}, problem: { nil }))
        )

        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.minSize]
        if #available(macOS 14, *) { controller.sceneBridgingOptions = [.all] }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: sizes[1]),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        if #unavailable(macOS 14) { window.title = "HyperSpace" }
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // On screen (the views only lay out and draw there) but invisible and untouchable.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()

        var failures = 0
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for size in sizes {
                window.setContentSize(size)
                for page in SettingsNavigation.Page.allCases {
                    navigation.page = page
                    settle(window)
                    let name = "\(page.fileName)-\(appearanceName)-\(Int(size.width))x\(Int(size.height)).png"
                    if let error = save(window, to: directory.appendingPathComponent(name)) {
                        fputs("\(name): \(error)\n", stderr)
                        failures += 1
                    } else {
                        print(name)
                    }
                }
            }
        }
        window.orderOut(nil)
        return failures == 0 ? 0 : 1
    }

    /// A few turns of the run loop so SwiftUI lays the page out and the images load.
    private static func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
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
