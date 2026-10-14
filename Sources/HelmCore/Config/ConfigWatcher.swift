import Foundation

/// Calls `onChange` (on the main queue) when the config file is created, edited, replaced or deleted.
///
/// Editors usually save atomically (write a temp file, then rename), which replaces the inode.
/// So we watch the parent directory for entries coming and going, plus the file itself for
/// in-place writes, and re-arm the file watch after every event. Events are debounced and
/// only reported when the file's content actually changed.
public final class ConfigWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "helm.config-watcher")
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var lastContent: Data?

    public init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    public func start() {
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            lastContent = try? Data(contentsOf: url)
            directorySource = makeSource(path: url.deletingLastPathComponent().path, mask: .write)
            armFileSource()
        }
    }

    public func stop() {
        queue.sync {
            directorySource?.cancel()
            fileSource?.cancel()
            directorySource = nil
            fileSource = nil
        }
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, mask: [.write, .extend, .delete, .rename])
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
        armFileSource()
        let content = try? Data(contentsOf: url)
        guard content != lastContent else { return }
        lastContent = content
        let onChange = onChange
        Task { @MainActor in onChange() }
    }
}
