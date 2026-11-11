import AppKit

/// Loads `~/.hyperspace/config.json` and reloads it when it changes.
/// Watching uses a kqueue vnode source: zero cost while the file is untouched.
final class ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hyperspace/config.json")

    var onChange: ((Result<Config, Error>) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    /// Editors often emit several events per save: one reload for them all.
    private let reloadDebouncer = Debouncer(delay: 0.15)
    /// One of the events coalesced replaced the file: watch the new one.
    private var rewatchPending = false

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

    /// `retryDelay`: how long to wait before looking again when the file is not there.
    /// `isRetry`: the file was missing at the last look, so what is found now is loaded too.
    private func watch(retryDelay: TimeInterval = 1, isRetry: Bool = false) {
        source?.cancel()
        source = nil

        let fd = open(Self.url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The editor may be mid-save (atomic rename): try again shortly. A file deleted for
            // good is looked for less and less often, up to every 30 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.watch(retryDelay: min(retryDelay * 2, 30), isRetry: true)
            }
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
        // A file that came back (deleted, then written again later) has not been read yet.
        if isRetry { reload() }
    }

    private func scheduleReload(rewatch: Bool) {
        rewatchPending = rewatchPending || rewatch
        reloadDebouncer.schedule { [weak self] in
            guard let self else { return }
            if rewatchPending {
                rewatchPending = false
                watch()
            }
            reload()
        }
    }
}
