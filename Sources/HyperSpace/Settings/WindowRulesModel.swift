import Combine
import Foundation

/// State of the Window Rules page: the floating rules (whole apps and titles) and the
/// scratchpad apps with their shortcuts. Changes go to the file through the shared `TilingModel`.
final class WindowRulesModel: ObservableObject {
    typealias ScratchpadApp = TilingModel.ScratchpadApp

    /// Bundle identifiers of apps whose windows are never tiled.
    @Published private(set) var floating: [String] = []
    @Published private(set) var floatingWindows: [FloatingWindowRule] = []
    /// The title rule being written: its own object, so typing its title redraws that row only.
    let floatingDraft = FloatingRuleDraft()
    @Published private(set) var scratchpadApps: [ScratchpadApp] = []

    /// The writer the four window pages share.
    weak var store: TilingModel?

    private func edit(_ change: () -> Void) {
        guard let store else { return change() }
        store.edit(change)
    }

    /// Every shortcut of the page, for the duplicate check.
    var shortcutKeys: [String] { scratchpadApps.flatMap { [$0.toggleKeys, $0.tileKeys] } }

    // MARK: - Floating

    /// Floats every window of an app (the section's *Add App*).
    func addFloating(_ bundleID: String) {
        guard !floating.contains(bundleID) else { return }
        edit { floating.append(bundleID) }
    }

    func removeFloating(_ bundleID: String) {
        edit { floating.removeAll { $0 == bundleID } }
    }

    func removeFloatingWindow(_ rule: FloatingWindowRule) {
        edit { floatingWindows.removeAll { $0 == rule } }
    }

    /// Adds the title rule being written, for its app or for any. A rule that already exists
    /// is not added (the page disables Add and says so).
    func addFloatingRule() {
        let app = floatingDraft.app, title = floatingDraft.trimmedTitle
        guard floatingDraft.canAdd, let rule = TilingConfig.floatingRule(app: app, title: title),
              !floatingWindows.contains(rule) else { return }
        edit { floatingWindows.append(rule) }
        floatingDraft.title = ""
    }

    // MARK: - Scratchpad

    /// Adds an app and records its show/hide shortcut right away.
    func addScratchpadApp(_ bundleID: String) {
        if !scratchpadApps.contains(where: { $0.bundleID == bundleID }) {
            scratchpadApps.append(ScratchpadApp(bundleID: bundleID))
        }
        store?.startCapture(.shortcut(ScratchpadApp(bundleID: bundleID).toggleAction))
    }

    func removeScratchpadApp(_ bundleID: String) {
        store?.stopCapture()
        edit { scratchpadApps.removeAll { $0.bundleID == bundleID } }
    }

    /// A capture ended with nothing recorded: an app with no shortcut yet goes (it is not
    /// saved), except the one a shortcut of which is recorded `next`.
    func dropAppsWithoutShortcut(keeping next: TilingModel.Field?) {
        let kept = scratchpadApps.filter { pad in
            pad.hasShortcut || next == .shortcut(pad.toggleAction) || next == .shortcut(pad.tileAction)
        }
        assignIfChanged(kept, to: &scratchpadApps)
    }

    /// The keys recorded for `action`, when it is a scratchpad app's (called inside the store's
    /// `edit`). An app that cleared both shortcuts, or never got one, is not saved, so not
    /// listed either.
    func setKeys(_ keys: String, for action: String) {
        var pads = scratchpadApps
        if let index = pads.firstIndex(where: { $0.toggleAction == action }) { pads[index].toggleKeys = keys }
        if let index = pads.firstIndex(where: { $0.tileAction == action }) { pads[index].tileKeys = keys }
        pads.removeAll { !$0.hasShortcut }
        assignIfChanged(pads, to: &scratchpadApps)
    }

    // MARK: - Persistence

    /// Shows the `tiling` section and the bindings of the file.
    func load(_ tiling: [String: Any], bindings: [[String: Any]]) {
        var apps: [String] = []
        for app in tiling["floating"] as? [String] ?? [] where !apps.contains(app) { apps.append(app) }
        // The rules as the config reads them; one listed twice shows once (the lists are keyed by rule).
        var rules: [FloatingWindowRule] = []
        for entry in tiling["floatingWindows"] as? [[String: Any]] ?? [] {
            guard let title = entry["title"] as? String,
                  let rule = TilingConfig.floatingRule(app: entry["app"] as? String, title: title),
                  !rules.contains(rule) else { continue }
            rules.append(rule)
        }
        assignIfChanged(apps, to: &floating)
        assignIfChanged(rules, to: &floatingWindows)

        // A scratchpad app being recorded has no binding yet: it stays.
        let pads = TilingModel.scratchpadApps(from: bindings)
        let recording = scratchpadApps.filter { pad in !pad.hasShortcut && !pads.contains { $0.bundleID == pad.bundleID } }
        assignIfChanged(pads + recording, to: &scratchpadApps)
    }
}

/// The title rule being written on the Window Rules page: app (nil for any) and title text.
final class FloatingRuleDraft: ObservableObject {
    @Published var app: String?
    @Published var title = ""

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }

    /// A title rule needs its title; the app is optional (none: any app).
    var canAdd: Bool { !trimmedTitle.isEmpty }
}
