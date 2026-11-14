import SwiftUI

/// The Window Rules page: windows kept out of the tiling, and the scratchpad apps.
struct WindowRulesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHero(page: .windowRules)
            PermissionNotice()
            SaveErrorNotice(status: model.saveStatus)
            TilingOffNotice(model: model)

            Section {
                if model.floating.isEmpty && model.floatingWindows.isEmpty {
                    EmptyRow(symbol: "macwindow", text: "No floating rules: every window is tiled")
                }
                ForEach(model.floating, id: \.self) { bundleID in
                    AppRuleRow(app: bundleID, remove: { model.removeFloating(bundleID) }) {
                        Text("All windows").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.floatingWindows, id: \.self) { rule in
                    AppRuleRow(app: rule.app, remove: { model.removeFloatingWindow(rule) }) {
                        Text("Title contains “\(rule.title)”").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                NewFloatingRule(model: model, draft: model.floatingDraft, apps: model.runningApps,
                                floating: model.floating, floatingWindows: model.floatingWindows)
            } header: {
                Text("Floating")
            } footer: {
                SectionFooter("Floating windows keep their own size and position. Pick an app to float all its windows, or add a title to float only some, such as its settings.")
            }

            Section {
                if model.scratchpadApps.isEmpty {
                    EmptyRow(symbol: "rectangle.on.rectangle", text: "No scratchpad apps: add one to show and hide it with a shortcut")
                } else {
                    ShortcutGrid(columns: ["Show / hide", "To tiling and back"], leading: "App", trailing: RemoveButton.width) {
                        ForEach(model.scratchpadApps) { pad in
                            GridRow {
                                AppLabel(bundleID: pad.bundleID)
                                    .frame(minWidth: 100, alignment: .leading)
                                ShortcutCap(model: model, keys: pad.toggleKeys, field: .shortcut(pad.toggleAction))
                                    .equatable()
                                ShortcutCap(model: model, keys: pad.tileKeys, field: .shortcut(pad.tileAction))
                                    .equatable()
                                Spacer(minLength: 0)
                                RemoveButton { model.removeScratchpadApp(pad.bundleID) }
                            }
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Scratchpad Apps") {
                    AddAppMenu(candidates: model.scratchpadCandidates, chooseTitle: "Other App…",
                               add: model.addScratchpadApp, choose: model.chooseAppForScratchpad)
                }
            } footer: {
                SectionFooter("Show / hide puts the app centered above the other windows, and hides it again. To tiling and back moves its window into the current workspace, and back into the scratchpad. " + ShortcutRecorder.hint)
            }
        }
        .formStyle(.grouped)
    }
}

/// The last row of the floating rules: the rule being written. It observes the draft alone, so
/// a keystroke in the title redraws this row, not the page. A rule already listed cannot be
/// added again, and says so.
private struct NewFloatingRule: View {
    let model: TilingModel
    @ObservedObject var draft: FloatingRuleDraft
    let apps: [(name: String, bundleID: String)]
    let floating: [String]
    let floatingWindows: [FloatingWindowRule]

    var body: some View {
        let exists = TilingModel.floatingRuleExists(app: draft.app, title: draft.title,
                                                    floating: floating, floatingWindows: floatingWindows)
        HStack(spacing: 8) {
            FloatingAppPicker(app: draft.app, apps: apps) { draft.app = $0 }
                .equatable()
            TextField("Title", text: $draft.title, prompt: Text("Title contains… (optional)"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addFloatingRule() }
            WarningBadge(text: exists ? "This rule is already in the list" : nil)
            AddButton(title: "Add") { model.addFloatingRule() }
                .disabled(!draft.canAdd || exists)
        }
    }
}

/// The app of the rule being written, among the running apps. Built again only when the
/// choice or the apps change (`==`), not on every keystroke in the title.
private struct FloatingAppPicker: View, Equatable {
    let app: String?
    let apps: [(name: String, bundleID: String)]
    let choose: (String?) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.app == b.app && a.apps.map(\.bundleID) == b.apps.map(\.bundleID)
    }

    var body: some View {
        Picker("App", selection: Binding(get: { app }, set: choose)) {
            Text("Any app").tag(String?.none)
            Divider()
            ForEach(apps, id: \.bundleID) { app in
                Text(app.name).tag(Optional(app.bundleID))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
