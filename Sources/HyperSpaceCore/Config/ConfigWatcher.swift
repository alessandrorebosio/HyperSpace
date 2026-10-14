import Foundation

/// Calls `onChange` (on the main queue) when any of the config files in one directory is
/// created, edited, replaced or deleted.
///
/// Editors usually save atomically (write a temp file, then rename), which replaces the inode.
/// So we watch the directory for entries coming and going, plus each file for in-place writes,
/// and re-arm the file watches after every event. Events are debounced and only reported when
/// some file's content actually changed.
public final class ConfigWatcher: @unchecked Sendable {
    private let directory: URL
    private let files: [URL]
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "hyperspace.config-watcher")
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSources: [any DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var lastContent: [Data?] = []

    public init(directory: URL, files: [URL], onChange: @escaping @MainActor @Sendable () -> Void) {
        self.directory = directory
        self.files = files
        self.onChange = onChange
    }

    public func start() {
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lastContent = readAll()
            directorySource = makeSource(path: directory.path, mask: .write)
            armFileSources()
        }
    }

    public func stop() {
        queue.sync {
            directorySource?.cancel()
            directorySource = nil
            fileSources.forEach { $0.cancel() }
            fileSources = []
        }
    }

    deinit {
        directorySource?.cancel()
        fileSources.forEach { $0.cancel() }
    }

    private func readAll() -> [Data?] {
        files.map { try? Data(contentsOf: $0) }
    }

    private func armFileSources() {
        fileSources.forEach { $0.cancel() }
        fileSources = files.compactMap { makeSource(path: $0.path, mask: [.write, .extend, .delete, .rename]) }
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func check() {
        armFileSources()
        let content = readAll()
        guard content != lastContent else { return }
        lastContent = content
        let onChange = onChange
        Task { @MainActor in onChange() }
    }
}
