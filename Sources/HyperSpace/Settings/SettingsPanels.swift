import AppKit
import UniformTypeIdentifiers

/// The panels the settings pages open. They belong to the views: a model is told what was
/// chosen, it never asks.
enum SettingsPanels {
    /// Asks for any installed app, running or not; its bundle identifier.
    static func chooseApp(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Asks where the config file `current` should go (a file already there is replaced, once
    /// the panel has asked).
    static func configDestination(for current: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Move Config File"
        panel.message = "HyperSpace moves its config file here and reads it from here from now on."
        panel.prompt = "Move"
        panel.nameFieldStringValue = current.lastPathComponent
        panel.directoryURL = GeneralModel.suggestedFolder
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a config file that already exists (in a dotfiles folder, say).
    static func existingConfig() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Use Another Config File"
        panel.message = "HyperSpace reads this file from now on; the current one stays where it is."
        panel.prompt = "Use"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = GeneralModel.suggestedFolder
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
