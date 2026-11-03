import AppKit

/// Loads `~/.hyperspace/config.json` and reloads it when it changes.
/// Watching uses a kqueue vnode source: zero cost while the file is untouched.
final class ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hyperspace/config.json")
    /// Where earlier versions kept it: moved to `url` on first start.
    private static let legacyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/hyperspace/config.json")

    var onChange: ((Result<Config, Error>) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    func start() {
        migrateLegacyConfig()
        writeDefaultIfMissing()
        reload()
        watch()
    }

    func reload() {
        onChange?(Result { try Config.load(from: Self.url) })
    }

    func openInEditor() {
        writeDefaultIfMissing()
        NSWorkspace.shared.open(Self.url)
    }

    /// A config in the old place (`~/.config/hyperspace`) moves to the new one, so there is
    /// only ever one file; the old folder goes too once empty.
    private func migrateLegacyConfig() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.url.path), fm.fileExists(atPath: Self.legacyURL.path) else { return }
        do {
            try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: Self.legacyURL, to: Self.url)
            let folder = Self.legacyURL.deletingLastPathComponent()
            // Finder's .DS_Store does not count.
            if let left = try? fm.contentsOfDirectory(atPath: folder.path), left.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: folder)
            }
            log.info("config moved to \(Self.url.path, privacy: .public)")
        } catch {
            log.error("cannot move the config to \(Self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeDefaultIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.url.path) else { return }
        do {
            try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DefaultConfig.json.write(to: Self.url, atomically: true, encoding: .utf8)
        } catch {
            log.error("cannot write default config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func watch() {
        source?.cancel()
        source = nil

        let fd = open(Self.url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The editor may be mid-save (atomic rename): try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self, unowned source] in
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            self?.scheduleReload(rewatch: replaced)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Editors often emit several events per save; coalesce them.
    private func scheduleReload(rewatch: Bool) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if rewatch { self?.watch() }
            self?.reload()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
