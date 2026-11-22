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
    /// When the config is a symbolic link, the link itself: pointing it at another file says
    /// nothing on the file it pointed at.
    private var linkSource: DispatchSourceFileSystemObject?
    /// The next look for a missing file: one at a time, whoever asks to watch again.
    private var retry: DispatchWorkItem?
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
        log.info("config file: \(url.abbreviatedPath, privacy: .public)")
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
        // A link whose file is missing gets the file, where it points: the link stays a link.
        let target = fileURL.linkTarget
        guard !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DefaultConfig.json.write(to: target, atomically: true, encoding: .utf8)
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
        linkSource?.cancel()
        linkSource = nil
        retry?.cancel()
        retry = nil

        // The link first: it is there to watch even while the file it points at is not.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) != nil {
            linkSource = fileSource(flags: O_EVTONLY | O_SYMLINK, events: [.delete, .rename]) { [weak self] _ in
                self?.scheduleReload(rewatch: true)
            }
        }
        let events: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename]
        source = fileSource(flags: O_EVTONLY, events: events) { [weak self] seen in
            self?.scheduleReload(rewatch: !seen.isDisjoint(with: [.delete, .rename]))
        }
        guard source != nil else {
            // The editor may be mid-save (atomic rename): try again shortly. A file deleted for
            // good is looked for less and less often, up to every 30 s.
            let retry = DispatchWorkItem { [weak self] in
                self?.watch(retryDelay: min(retryDelay * 2, 30), isRetry: true)
            }
            self.retry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: retry)
            return
        }
        // A file that came back (deleted, then written again later) has not been read yet.
        if isRetry { reload() }
    }

    /// A running kqueue source on the config's path opened with `flags`, nil when it cannot
    /// be opened; `onEvent` gets the events seen, on the main thread.
    private func fileSource(flags: Int32, events: DispatchSource.FileSystemEvent,
                            onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(fileURL.path, flags)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [unowned source] in onEvent(source.data) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
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
