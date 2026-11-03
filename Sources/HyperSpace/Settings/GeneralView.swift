import AppKit
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
    /// Outcome of the last action on this page.
    @Published private(set) var status: (text: String, ok: Bool)?

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
        status = actions.problem().map { ($0, false) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            status = ("Launch at login: \(error.localizedDescription)", false)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
            PageHeader()

            Section {
                LabeledContent {
                    Text(model.version).foregroundStyle(.secondary)
                } label: {
                    IconLabel("Version", symbol: "info", color: .gray)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    IconLabel("Launch at Login", detail: "Start HyperSpace automatically when you log in.",
                              symbol: "power", color: .green)
                }
            } header: {
                Text("Startup")
            }

            Section {
                LabeledContent {
                    Text(model.configPath).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    IconLabel("File", symbol: "doc.text.fill", color: .blue)
                }
                HStack {
                    Button("Edit Config…") { model.actions.openConfig() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
                    Spacer()
                }
                if let status = model.status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? Color.green : Color.orange)
                }
            } header: {
                Text("Configuration")
            } footer: {
                SectionFooter("The file is watched: changes made here or saved in an editor apply as soon as they are saved.")
            }

            Section {
                LabeledContent {
                    if model.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") { Permissions.openSettings() }
                    }
                } label: {
                    IconLabel("Accessibility", symbol: "accessibility", color: .blue)
                }
            } header: {
                Text("Permission")
            } footer: {
                SectionFooter("Key remapping works without it; shortcuts, mouse buttons and window management need it.")
            }

            Section {
                Button(role: .destructive) { NSApp.terminate(nil) } label: {
                    Text("Quit HyperSpace").frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}
