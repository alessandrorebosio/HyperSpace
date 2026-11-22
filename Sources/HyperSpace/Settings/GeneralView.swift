import AppKit
import SwiftUI

/// The General page: the app and its state, startup, the config file, the permission.
struct GeneralView: View {
    @ObservedObject var model: GeneralModel
    @Environment(\.openConfig) private var openConfig

    var body: some View {
        Form {
            Section {
                AppCard(model: model)
            }

            PermissionNotice(detail: "Key remapping already works. Shortcuts, mouse buttons and window management need HyperSpace to be allowed in \(Wording.accessibilityPane).")
                .environment(\.permissionMissing, !model.accessibilityGranted)

            Section {
                SwitchRow(title: "Launch at login", detail: "Start HyperSpace when you log in.",
                          isOn: model.launchAtLogin, set: model.setLaunchAtLogin)
                if let error = model.loginError {
                    ErrorLabel(error)
                }
            } header: {
                Text("Startup")
            }

            Section {
                SettingRow(title: "Config file") {
                    Text(model.configPath)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let error = model.configLocationError {
                    ErrorLabel(error)
                }
                if let problem = model.configProblem {
                    ErrorLabel(problem)
                }
                HStack {
                    Button(Wording.editConfig, action: openConfig)
                    Button("Show in Finder") { model.showConfigInFinder() }
                    Spacer()
                    Button("Move…") {
                        if let url = SettingsPanels.configDestination(for: model.configURL) { model.relocate(to: url, moving: true) }
                    }
                    .help("Move the config file to another folder (~/.config/hyperspace, a dotfiles folder…)")
                    Button("Use Another File…") {
                        if let url = SettingsPanels.existingConfig() { model.relocate(to: url, moving: false) }
                    }
                    .help("Read an existing config file from now on; the current one stays where it is")
                }
            } header: {
                Text("Configuration")
            } footer: {
                SectionFooter("Everything on these pages is saved there. Changes made in an editor apply as soon as the file is saved. The file can live anywhere: HyperSpace remembers where.")
            }

            Section {
                SettingRow(title: "Accessibility", detail: "The only permission HyperSpace asks for.") {
                    if model.accessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(Wording.openSystemSettings) { model.openAccessibilitySettings() }
                    }
                }
            } header: {
                Text("Permission")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit HyperSpace", role: .destructive) { model.quit() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}

/// The app's icon, name, version and state, at the top of the General page.
private struct AppCard: View {
    @ObservedObject var model: GeneralModel

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("HyperSpace").font(.title3.weight(.semibold))
                Text("Version \(AppInfo.version)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Metrics.rowGap)
            StatusPill(text: model.health.text, color: model.health.color)
        }
        .padding(.vertical, 4)
    }
}
