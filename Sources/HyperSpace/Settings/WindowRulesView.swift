import SwiftUI

/// The Window Rules page: windows kept out of the tiling, and the scratchpad apps.
struct WindowRulesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHero(page: .windowRules)
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
                if model.floating.isEmpty && model.floatingWindows.isEmpty {
                    EmptyRow(symbol: "macwindow", text: "Every window is tiled")
                }
                ForEach(model.floating, id: \.self) { bundleID in
                    HStack(spacing: 10) {
                        AppLabel(bundleID: bundleID)
                        Spacer(minLength: 12)
                        Text("All windows").foregroundStyle(.secondary)
                        RemoveButton { model.removeFloating(bundleID) }
                    }
                }
                ForEach(model.floatingWindows, id: \.self) { rule in
                    HStack(spacing: 10) {
                        if let app = rule.app {
                            AppLabel(bundleID: app)
                        } else {
                            Label("Any app", systemImage: "square.grid.2x2").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text("Title contains “\(rule.title)”").foregroundStyle(.secondary).lineLimit(1)
                        RemoveButton { model.removeFloatingWindow(rule) }
                    }
                }
                NewFloatingRule(model: model)
            } header: {
                Text("Floating")
            } footer: {
                SectionFooter("Floating windows keep their own size and position. Pick an app to float all its windows, or add a title to float only some, such as its settings.",
                              error: model.saveError)
            }

            Section {
                if model.scratchpadApps.isEmpty {
                    EmptyRow(symbol: "rectangle.on.rectangle", text: "No scratchpad apps yet")
                } else {
                    ShortcutGrid(columns: ["Show / hide", "To tiling and back"], leading: "App", trailing: RemoveButton.width) {
                        ForEach(model.scratchpadApps) { pad in
                            GridRow {
                                AppLabel(bundleID: pad.bundleID)
                                    .frame(minWidth: 100, alignment: .leading)
                                ShortcutCap(model: model, keys: pad.toggleKeys, field: .shortcut(pad.toggleAction))
                                ShortcutCap(model: model, keys: pad.tileKeys, field: .shortcut(pad.tileAction))
                                Spacer(minLength: 0)
                                RemoveButton { model.removeScratchpadApp(pad.bundleID) }
                            }
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Scratchpad Apps") {
                    AddAppMenu(candidates: model.scratchpadCandidates, chooseTitle: "Choose App…",
                               add: model.addScratchpadApp, choose: model.chooseAppForScratchpad)
                }
            } footer: {
                SectionFooter("Show / hide puts the app centered above the other windows, and hides it again. To tiling and back moves its window into the current workspace, and back into the scratchpad.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The last row of the floating rules: the rule being written.
private struct NewFloatingRule: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("App", selection: $model.newFloatingApp) {
                Text("Any app").tag(String?.none)
                Divider()
                ForEach(AppLauncher.runningApps, id: \.bundleID) { app in
                    Text(app.name).tag(Optional(app.bundleID))
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Title", text: $model.newFloatingTitle,
                      prompt: Text("Title contains… (optional)"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addFloatingRule() }
            AddButton(title: "Add") { model.addFloatingRule() }
                .disabled(!model.canAddFloatingRule)
        }
    }
}
