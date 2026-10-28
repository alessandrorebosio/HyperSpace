import AppKit
import ServiceManagement
import SwiftUI

/// The "Settings" page: startup, config file, permission and quit.
final class GeneralModel: ObservableObject {
    struct Actions {
        var openConfig: () -> Void
        var reloadConfig: () -> Void
        /// The current problem shown in the menu bar (config error, missing permission).
        var problem: () -> String?
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var status: String?

    let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        refresh()
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityGranted = Permissions.isTrusted(prompt: false)
        status = actions.problem()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            status = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func reload() {
        actions.reloadConfig()
        // The reload is synchronous; show its outcome.
        status = actions.problem() ?? "Config reloaded"
    }

    var configPath: String {
        (ConfigStore.url.path as NSString).abbreviatingWithTildeInPath
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

struct GeneralView: View {
    @ObservedObject var model: GeneralModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Launch at Login")
                    Text("Start HyperSpace automatically when you log in.")
                }
            } header: {
                Text("Startup")
            }

            Section {
                LabeledContent("File") {
                    Text(model.configPath).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Edit Config…") { model.actions.openConfig() }
                    Button("Reload Config") { model.reload() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
                    Spacer()
                }
                if let status = model.status {
                    Label(status, systemImage: status == "Config reloaded" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status == "Config reloaded" ? Color.green : Color.orange)
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("The file is watched: changes made here or saved in an editor apply automatically. Use Reload if a change did not apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") { Permissions.openSettings() }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("Key remapping works without it; shortcuts, mouse buttons and window management need it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("HyperSpace \(model.version)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit HyperSpace", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}
