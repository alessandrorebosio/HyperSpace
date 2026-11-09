import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The "Settings" page: startup, config file, permission and quit.
final class GeneralModel: ObservableObject {
    struct Actions {
        var openConfig: () -> Void
        /// The current problem shown in the menu bar (config error, missing permission).
        var problem: () -> String?
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = false
    /// What needs attention: the problem shown in the menu bar, or the last action that failed here.
    @Published private(set) var problem: String?

    let actions: Actions
    private var activation: Any?

    init(actions: Actions) {
        self.actions = actions
        refresh()
        // Back from System Settings: the permission may have just been granted.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.accessibilityGranted = Permissions.isTrusted(prompt: false)
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityGranted = Permissions.isTrusted(prompt: false)
        problem = actions.problem()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            problem = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var configPath: String {
        (ConfigStore.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// How the app is doing, in a few words with a color: on the sidebar and the General page.
    var health: (text: String, color: Color) {
        if !accessibilityGranted { return ("Accessibility needed", .orange) }
        if problem != nil { return ("Needs attention", .red) }
        return ("Running", .green)
    }
}

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
                        .foregroundStyle(.orange)
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

/// A colored dot and a word, on a tinted capsule.
private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
