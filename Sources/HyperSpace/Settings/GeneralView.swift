import AppKit
import SwiftUI

/// The General page: the app and its state, startup, the config file, the permission.
struct GeneralView: View {
    @ObservedObject var model: GeneralModel

    var body: some View {
        Form {
            Section {
                AppCard(model: model)
            }

            PermissionNotice(detail: "Key remapping already works. Shortcuts, mouse buttons and window management need HyperSpace to be allowed in Privacy & Security → Accessibility.")
                .environment(\.permissionMissing, !model.accessibilityGranted)

            Section {
                SwitchRow(title: "Launch at login", detail: "Start HyperSpace when you log in.",
                          isOn: model.launchAtLogin, set: model.setLaunchAtLogin)
            } header: {
                Text("Startup")
            } footer: {
                if let error = model.loginError {
                    SectionFooter(error: error)
                }
            }

            Section {
                LabeledContent {
                    Text(model.configPath)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    RowLabel("Config file")
                }
                if let error = model.configLocationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = model.configProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Edit Config…") { model.actions.openConfig() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
                    Spacer()
                    Button("Move…") { model.moveConfig() }
                        .help("Move the config file to another folder (~/.config/hyperspace, a dotfiles folder…)")
                    Button("Use Another File…") { model.useOtherConfig() }
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
                        Button("Open System Settings…") { Permissions.openSettings() }
                    }
                }
            } header: {
                Text("Permission")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit HyperSpace", role: .destructive) { NSApp.terminate(nil) }
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
            Spacer(minLength: 12)
            StatusPill(text: model.health.text, color: model.health.color)
        }
        .padding(.vertical, 4)
    }

}

/// A colored dot and a word: on a tinted capsule, or plain and small (the sidebar).
struct StatusPill: View {
    let text: String
    let color: Color
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
        }
    }
}
