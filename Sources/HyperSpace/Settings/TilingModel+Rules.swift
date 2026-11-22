import Foundation

// The rules of the window pages as pure functions: what the file means, what is written back,
// what counts as a duplicate. No state: the page models call them, and the tests do.

extension TilingModel {
    /// The display choices for a workspace pinned to `pin`: automatic; a display by position
    /// (the main one, the second, the third…: whichever monitor is there, written as "main" or
    /// its number); then every connected monitor by name; and the pin itself when it is none of
    /// these (a monitor not connected, a fourth display, a name typed in the file).
    static func displayOptions(pin: String, screens: [ScreenInfo]) -> [DisplayOption] {
        var options = [DisplayOption(value: "", label: "Any display"), DisplayOption(value: "main", label: "Main display")]
        for number in 2...max(3, screens.count) {
            options.append(DisplayOption(value: String(number), label: positionLabel(number)))
        }
        for (index, screen) in screens.enumerated() {
            let name = screen.name.isEmpty ? "Display \(index + 1)" : screen.name
            options.append(DisplayOption(value: screen.pinValue(among: screens), label: name, startsGroup: index == 0))
        }
        let pin = pin.trimmingCharacters(in: .whitespaces)
        if !pin.isEmpty, !options.contains(where: { $0.value == pin }) {
            let label: String
            if pin.lowercased() == "main" || pin == "1" {
                label = "Main display"
            } else if let number = Int(pin), number > 1 {
                label = positionLabel(number)
            } else {
                let connected = ScreenInfo.pinned(pin, among: screens)
                label = connected.map { $0.name.isEmpty ? pin : $0.name } ?? "\(pin) (not connected)"
            }
            options.append(DisplayOption(value: pin, label: label, startsGroup: true))
        }
        return options
    }

    /// "Second display", "Third display", then "Display 4"… (the first is the main one).
    static func positionLabel(_ number: Int) -> String {
        switch number {
        case 2: return "Second display"
        case 3: return "Third display"
        default: return "Display \(number)"
        }
    }

    /// The workspaces and app rules once workspace `id` is removed: its rules go with it (the
    /// file loses them too), rules naming no workspace stay as they were.
    static func removing(_ id: UUID, from workspaces: [Workspace], assignments: [Assignment])
        -> (workspaces: [Workspace], assignments: [Assignment]) {
        (workspaces.filter { $0.id != id }, assignments.filter { $0.workspace != id })
    }

    /// What goes when `workspace` is removed, one line each, for the confirmation.
    static func removalLosses(of workspace: Workspace, assignments: [Assignment], appName: (String) -> String) -> [String] {
        var losses: [String] = []
        let keys = [workspace.switchKeys, workspace.moveKeys].filter { !$0.isEmpty }
        if !keys.isEmpty {
            losses.append((keys.count == 1 ? "Its shortcut " : "Its shortcuts ") + keys.map(RemapTarget.label).joined(separator: " and "))
        }
        let apps = assignments.filter { $0.workspace == workspace.id }.map { appName($0.app) }
        if !apps.isEmpty {
            losses.append((apps.count == 1 ? "The app rule of " : "The app rules of ") + apps.joined(separator: ", "))
        }
        if !workspace.display.isEmpty { losses.append("Its display pin") }
        return losses
    }

    /// Whether the rule for `app` (nil: any) and `title` (empty: every window) is already listed.
    static func floatingRuleExists(app: String?, title: String, floating: [String], floatingWindows: [FloatingWindowRule]) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return app.map(floating.contains) ?? false }
        guard let rule = TilingConfig.floatingRule(app: app, title: title) else { return false }
        return floatingWindows.contains(rule)
    }

    /// The running apps that are not in `taken` yet: what an Add App menu offers.
    static func candidates(_ apps: [(name: String, bundleID: String)], excluding taken: Set<String>) -> [(name: String, bundleID: String)] {
        apps.filter { !taken.contains($0.bundleID) }
    }

    /// The regular apps running, one entry per app: an app running twice (`open -n`) is listed
    /// once, so the menus built from the list have no two rows with the same id.
    static func uniqueApps(_ apps: [(name: String, bundleID: String)]) -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID).inserted }
    }

    /// A name as it is saved: without the spaces around it ("web " would look like "web").
    static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Why a typed name is not saved, if it is not.
    static func nameWarning(typed: String, saved: String, others: Set<String>) -> String? {
        guard trimmedName(typed) != saved, !isValidName(typed, others: others) else { return nil }
        return trimmedName(typed).isEmpty
            ? "A workspace needs a name: \"\(saved)\" is kept"
            : "Another workspace has this name: \"\(saved)\" is kept"
    }

    /// A name can be saved when, trimmed, it is not empty and not another workspace's.
    static func isValidName(_ name: String, others: Set<String>) -> Bool {
        let name = trimmedName(name)
        return !name.isEmpty && !others.contains(name)
    }

    /// The shortcuts (as `comboKey`) found more than once in `keys`; empty keys do not count.
    static func duplicates(_ keys: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for keys in keys where !keys.isEmpty { counts[comboKey(keys), default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// What a shortcut means, to compare two: its key code and modifiers, or the text itself
    /// when it does not parse.
    static func comboKey(_ keys: String) -> String {
        guard let combo = try? KeyCombo.parse(keys) else { return keys }
        return "\(combo.keyCode)/\(combo.modifiers.rawValue)"
    }

    /// Whether two action texts mean the same action ("Focus Left" and "focus left",
    /// "resize width 50" and "resize width +50"); texts that do not parse compare as text.
    static func sameAction(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let x = try? Action.parse(a), let y = try? Action.parse(b) else { return false }
        return x == y
    }

    /// The keys of the bindings no page shows: all but the last binding of each window
    /// shortcut and of each scratchpad action (the ones the pages show and edit).
    static func otherBindingKeys(_ bindings: [[String: Any]]) -> [String] {
        func action(_ binding: [String: Any]) -> String { binding["action"] as? String ?? "" }
        var shown = Set<Int>()
        for shortcut in shortcutActions {
            if let index = bindings.lastIndex(where: { sameAction(action($0), shortcut) }) { shown.insert(index) }
        }
        var lastScratchpad: [String: Int] = [:]
        for (index, binding) in bindings.enumerated() {
            let text = action(binding)
            if text.hasPrefix(togglePrefix) || text.hasPrefix(tilePrefix) { lastScratchpad[text] = index }
        }
        shown.formUnion(lastScratchpad.values)
        return bindings.indices.filter { !shown.contains($0) }.compactMap { bindings[$0]["keys"] as? String }
    }

    /// A display pin as the page holds it: without the spaces around it, and "main" in lowercase,
    /// so it is one of the display menu's choices however the file writes it.
    static func pin(_ text: String) -> String {
        let pin = text.trimmingCharacters(in: .whitespaces)
        return pin.lowercased() == "main" ? "main" : pin
    }

    /// The workspaces as the file holds them.
    static func workspaceEntries(_ workspaces: [Workspace]) -> [[String: Any]] {
        workspaces.map { workspace in
            var entry: [String: Any] = ["name": workspace.name]
            if !workspace.switchKeys.isEmpty { entry["switch"] = workspace.switchKeys }
            if !workspace.moveKeys.isEmpty { entry["move"] = workspace.moveKeys }
            if !workspace.display.isEmpty { entry["display"] = workspace.display }
            return entry
        }
    }

    /// The app rules of the file, each pointing at its workspace the way the config resolves it
    /// (by name, else by number).
    static func assignments(from entries: [[String: Any]], workspaces: [Workspace]) -> [Assignment] {
        let names = workspaces.map(\.name)
        return entries.compactMap { entry in
            guard let app = entry["app"] as? String, let text = entry["workspace"] as? String else { return nil }
            let index = TilingConfig.workspaceIndex(text, names: names)
            return Assignment(app: app, workspace: index.map { workspaces[$0].id }, text: text)
        }
    }

    /// The app rules as written: a rule keeps its text while it still points at its workspace
    /// ("2" stays "2"), else gets the workspace's name. Rules of a removed workspace go; a rule
    /// that named no workspace to begin with stays as it was (the config reports it).
    static func assignEntries(_ assignments: [Assignment], workspaces: [Workspace]) -> [[String: Any]] {
        let names = workspaces.map(\.name)
        return assignments.compactMap { rule in
            guard let id = rule.workspace else { return ["app": rule.app, "workspace": rule.text] }
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
            let keepsText = TilingConfig.workspaceIndex(rule.text, names: names) == index
            return ["app": rule.app, "workspace": keepsText ? rule.text : names[index]]
        }
    }

    /// The apps with scratchpad shortcuts among `bindings`, in order of first appearance; the
    /// last binding of each of their two actions gives its keys.
    static func scratchpadApps(from bindings: [[String: Any]]) -> [ScratchpadApp] {
        var pads: [ScratchpadApp] = []
        for binding in bindings {
            guard let action = binding["action"] as? String, let keys = binding["keys"] as? String else { continue }
            let toggle = action.hasPrefix(togglePrefix)
            guard toggle || action.hasPrefix(tilePrefix) else { continue }
            let bundleID = String(action.dropFirst((toggle ? togglePrefix : tilePrefix).count))
            let index = pads.firstIndex { $0.bundleID == bundleID } ?? {
                pads.append(ScratchpadApp(bundleID: bundleID))
                return pads.count - 1
            }()
            if toggle { pads[index].toggleKeys = keys } else { pads[index].tileKeys = keys }
        }
        return pads
    }

    /// `bindings` with the `desired` keys of each action. Each action's last binding (the one
    /// the page shows) is edited in place, or removed when its keys are empty; an action with
    /// no binding gets one at the end; other bindings, even more for the same action, stay where
    /// they are. Scratchpad bindings not in `scratchpadActions` (an app taken off the list) go.
    static func mergedBindings(_ bindings: [[String: Any]], desired: [(action: String, keys: String)],
                               scratchpadActions: Set<String>) -> [[String: Any]] {
        func actionText(_ binding: [String: Any]) -> String { binding["action"] as? String ?? "" }
        func sameAction(_ binding: [String: Any], _ action: String) -> Bool { Self.sameAction(actionText(binding), action) }
        var bindings = bindings
        bindings.removeAll {
            let action = actionText($0)
            return (action.hasPrefix(togglePrefix) || action.hasPrefix(tilePrefix)) && !scratchpadActions.contains(action)
        }
        var cleared = Set<Int>()
        var added: [[String: Any]] = []
        for entry in desired {
            if let index = bindings.lastIndex(where: { sameAction($0, entry.action) }) {
                if entry.keys.isEmpty {
                    cleared.insert(index)
                } else if bindings[index]["keys"] as? String != entry.keys {
                    bindings[index]["keys"] = entry.keys
                }
            } else if !entry.keys.isEmpty {
                added.append(["keys": entry.keys, "action": entry.action])
            }
        }
        return bindings.enumerated().filter { !cleared.contains($0.offset) }.map(\.element) + added
    }
}
