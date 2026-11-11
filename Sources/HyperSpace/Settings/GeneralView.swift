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
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Edit Config…") { model.actions.openConfig() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
                    Spacer()
                }
            } header: {
                Text("Configuration")
            } footer: {
                SectionFooter("Everything on these pages is saved there. Changes made in an editor apply as soon as the file is saved.")
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
