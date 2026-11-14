import AppKit

/// Loads the config file (`ConfigLocation`) and reloads it when it changes.
/// Watching uses a kqueue vnode source: zero cost while the file is untouched.
final class ConfigStore {
    /// The config file, read once at launch and changed only by `relocate`: the writers and the
    /// watcher always agree on it, whatever appears on disk meanwhile.
    private(set) static var url = ConfigLocation.current

    /// Posted on the main thread after every load, successful or not (`onChange` has run):
    /// the settings window follows the file with it.
    static let didLoad = Notification.Name("HyperSpace.configDidLoad")

    var onChange: ((Result<Config, Error>) -> Void)?

    /// The file watched: the real config, or a temporary one in the tests.
    private var fileURL: URL
    /// How long to wait before the first look for a missing file (doubling up to 30 s).
    private let firstRetryDelay: TimeInterval

    init(url: URL = ConfigStore.url, firstRetryDelay: TimeInterval = 1) {
        fileURL = url
        self.firstRetryDelay = firstRetryDelay
    }

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

    /// Uses the config at `url` from now on (Settings → General). `moving`: the current file
    /// goes there first (replacing one already there); otherwise the file there is used as it
    /// is (written with the defaults if missing). The choice is remembered for the next launches.
    func relocate(to url: URL, moving: Bool) throws {
        if moving { try ConfigLocation.move(from: fileURL, to: url) }
        ConfigLocation.choose(url)
        Self.url = url
        fileURL = url
        log.info("config file: \((url.path as NSString).abbreviatingWithTildeInPath, privacy: .public)")
        writeDefaultIfMissing()
        watch()
        reload()
    }

    func reload() {
        onChange?(Result { try Config.load(from: fileURL) })
        NotificationCenter.default.post(name: Self.didLoad, object: self)
    }

    func openInEditor() {
        writeDefaultIfMissing()
        NSWorkspace.shared.open(fileURL)
    }

    private func writeDefaultIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DefaultConfig.json.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("cannot write default config: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `retryDelay`: how long to wait before looking again when the file is not there.
    /// `isRetry`: the file was missing at the last look, so what is found now is loaded too.
    private func watch(retryDelay: TimeInterval? = nil, isRetry: Bool = false) {
        let retryDelay = retryDelay ?? firstRetryDelay
        source?.cancel()
        source = nil

        let fd = open(fileURL.path, O_EVTONLY)
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
