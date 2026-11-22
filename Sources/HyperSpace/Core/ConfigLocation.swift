import Foundation

/// Where the config file is. Each user picks it (Settings → General, or
/// `defaults write com.alessandrorebosio.HyperSpace configPath <path>`); with no choice it is
/// `~/.config/hyperspace/config.json`, or the older `~/.hyperspace/config.json` while only
/// that one exists.
enum ConfigLocation {
    /// The UserDefaults key of the path chosen (a file, or a folder for its `config.json`).
    static let defaultsKey = "configPath"
    static let fileName = "config.json"

    /// Where a new config goes when nothing was chosen.
    static func standard(home: URL) -> URL {
        home.appendingPathComponent(".config/hyperspace/\(fileName)")
    }

    /// Where the config was before it could be moved: still used while it is the only one.
    static func legacy(home: URL) -> URL {
        home.appendingPathComponent(".hyperspace/\(fileName)")
    }

    /// The config file: the path chosen when there is one (missing or not: it is created
    /// there), else the standard one if it exists, else the legacy one if it exists, else the
    /// standard one (a first launch).
    static func resolve(chosen: String?, home: URL, exists: (URL) -> Bool, isDirectory: (URL) -> Bool) -> URL {
        if let chosen = chosen?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            // "~" is `home`; "~name" is that user's home folder, which only the system knows.
            let ownHome = chosen == "~" || chosen.hasPrefix("~/")
            let expanded = ownHome ? home.path + chosen.dropFirst() : (chosen as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            return chosen.hasSuffix("/") || isDirectory(url) ? url.appendingPathComponent(fileName) : url
        }
        let standard = standard(home: home)
        if exists(standard) { return standard }
        let legacy = legacy(home: home)
        return exists(legacy) ? legacy : standard
    }

    /// The config file of this user, as chosen now.
    static var current: URL {
        let fm = FileManager.default
        return resolve(chosen: UserDefaults.standard.string(forKey: defaultsKey),
                       home: fm.homeDirectoryForCurrentUser,
                       exists: { fm.fileExists(atPath: $0.path) },
                       isDirectory: { url in
                           var directory: ObjCBool = false
                           return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
                       })
    }

    /// Remembers `url` as this user's config file (written with `~` when it is in the home folder).
    static func choose(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.abbreviatedPath, forKey: defaultsKey)
    }

    /// Moves the config from `source` to `destination`, replacing a file already there, and
    /// removes the legacy `~/.hyperspace` folder when that leaves it empty (no other folder is
    /// ever removed). A symbolic link is moved as the link, not the file it points to. Nothing
    /// happens when they are the same file; a source that does not exist is not an error (the
    /// default config is then written at the destination on the next load).
    static func move(from source: URL, to destination: URL, fileManager fm: FileManager = .default) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.attributesOfItem(atPath: source.path)) != nil else { return }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
        let folder = source.deletingLastPathComponent()
        guard folder.lastPathComponent == ".hyperspace" else { return }
        let left = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        if left.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: folder) }
    }
}
