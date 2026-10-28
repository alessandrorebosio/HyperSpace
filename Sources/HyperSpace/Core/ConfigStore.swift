import AppKit

/// Loads `~/.config/hyperspace/config.json` and reloads it when it changes.
/// Watching uses a kqueue vnode source: zero cost while the file is untouched.
final class ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/hyperspace/config.json")

    var onChange: ((Result<Config, Error>) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    func start() {
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
