import SwiftUI

/// The Window Rules page: windows kept out of the tiling, and the scratchpad apps.
struct WindowRulesView: View {
    /// What the window pages share: the save status, the shortcut caps' recording and duplicates.
    let store: TilingModel
    @ObservedObject var model: WindowRulesModel
    /// The cap being recorded and the shortcuts used twice: a change of either redraws the caps.
    @ObservedObject var capture: FieldCapture<TilingModel.Field>
    @ObservedObject var conflicts: ShortcutConflicts
    /// The apps running, for the app menus.
    @ObservedObject var apps: RunningApps

    var body: some View {
        Form {
            PageHero(page: .windowRules)
            PermissionNotice()
            SaveErrorNotice(status: store.saveStatus)
            TilingOffNotice(model: store.options)

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
                NewTitleRule(model: model, draft: model.floatingDraft, apps: apps.list,
                             floatingWindows: model.floatingWindows)
            } header: {
                SectionHeader(title: "Floating") {
                    AddAppMenu(candidates: apps.candidates(excluding: model.floating), add: model.addFloating) {
                        if let bundleID = SettingsPanels.chooseApp(prompt: "Add") { model.addFloating(bundleID) }
                    }
                    .help("Float every window of an app")
                }
            } footer: {
                SectionFooter("Floating windows keep their own size and position. Add an app to float all its windows, or write a title in the last row to float only the windows whose title contains it, such as an app's settings.")
            }

            Section {
                if model.scratchpadApps.isEmpty {
                    EmptyRow(symbol: "rectangle.on.rectangle", text: "No scratchpad apps: add one to show and hide it with a shortcut")
                } else {
                    ShortcutGrid(columns: ["Show / hide", "To tiling and back"], leading: "App", trailing: RemoveButton.width) {
                        ForEach(model.scratchpadApps) { pad in
                            let name = AppLauncher.name(pad.bundleID)
                            GridRow {
                                AppLabel(bundleID: pad.bundleID)
                                    .frame(minWidth: Metrics.appColumnWidth, alignment: .leading)
                                ShortcutCap(store: store, name: "Show or hide \(name)", keys: pad.toggleKeys,
                                            field: .shortcut(pad.toggleAction))
                                    .equatable()
                                ShortcutCap(store: store, name: "Move \(name) to the tiling and back", keys: pad.tileKeys,
                                            field: .shortcut(pad.tileAction))
                                    .equatable()
                                Spacer(minLength: 0)
                                RemoveButton(what: "\(name) from the scratchpad apps") { model.removeScratchpadApp(pad.bundleID) }
                            }
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Scratchpad Apps") {
                    AddAppMenu(candidates: apps.candidates(excluding: model.scratchpadApps.map(\.bundleID)), add: model.addScratchpadApp) {
                        if let bundleID = SettingsPanels.chooseApp(prompt: "Add") { model.addScratchpadApp(bundleID) }
                    }
                }
            } footer: {
                SectionFooter("Show / hide puts the app centered above the other windows, and hides it again. To tiling and back moves its window into the current workspace, and back into the scratchpad. " + ShortcutRecorder.hint)
            }
        }
        .formStyle(.grouped)
    }
}

/// The last row of the floating rules: the title rule being written, for an app or for any.
/// It observes the draft alone, so a keystroke in the title redraws this row, not the page.
/// A rule already listed cannot be added again, and says so.
private struct NewTitleRule: View {
    let model: WindowRulesModel
    @ObservedObject var draft: FloatingRuleDraft
    let apps: [(name: String, bundleID: String)]
    let floatingWindows: [FloatingWindowRule]

    var body: some View {
        let exists = !draft.trimmedTitle.isEmpty
            && TilingModel.floatingRuleExists(app: draft.app, title: draft.title, floating: [], floatingWindows: floatingWindows)
        HStack(spacing: Metrics.ruleSpacing) {
            TitleRuleAppMenu(app: draft.app, apps: apps) { draft.app = $0 }
                .equatable()
            TextField("Title", text: $draft.title, prompt: Text("Title contains…"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addFloatingRule() }
            WarningBadge(text: exists ? "This rule is already in the list" : nil)
            AddButton(title: "Add") { model.addFloatingRule() }
                .disabled(!draft.canAdd || exists)
                .help("Float the windows whose title contains this text")
        }
    }
}

/// The app of the title rule being written: any app, a running one, or any other installed
/// one (*Other App…*). It shows its choice by name, so an app that quits meanwhile stays
/// chosen. Built again only when the choice or the apps change (`==`), not on every keystroke
/// in the title.
private struct TitleRuleAppMenu: View, Equatable {
    let app: String?
    let apps: [(name: String, bundleID: String)]
    let choose: (String?) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.app == b.app && a.apps.map(\.bundleID) == b.apps.map(\.bundleID)
    }

    var body: some View {
        Menu {
            Button(Wording.anyApp) { choose(nil) }
            Divider()
            ForEach(apps, id: \.bundleID) { app in
                Button(app.name) { choose(app.bundleID) }
            }
            Divider()
            Button(Wording.otherApp) {
                if let bundleID = SettingsPanels.chooseApp(prompt: "Choose") { choose(bundleID) }
            }
        } label: {
            Text(app.map(AppLauncher.name) ?? Wording.anyApp)
        }
        .modifier(BorderedMenu(indicator: .visible))
        .help("The app whose windows the title rule floats")
        .accessibilityLabel("App of the title rule: \(app.map(AppLauncher.name) ?? Wording.anyApp)")
    }
}
