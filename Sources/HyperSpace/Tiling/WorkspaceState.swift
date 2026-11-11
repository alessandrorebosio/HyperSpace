import Foundation

/// The workspaces as they were when HyperSpace last saw them, so a restart (or a reboot,
/// as apps reopen their windows) puts every window back in its workspace and column.
/// Windows are recognised by app and title; the title may have changed (a browser tab),
/// so a window with an unknown title takes the next saved window of its app.
struct WorkspaceState: Codable, Equatable {
    struct Window: Codable, Equatable {
        var app: String
        var title: String
        var workspace: Int
        /// Set only when floating was toggled by hand.
        var floating: Bool?
        /// In the scratchpad (out of the tiling, shown on demand).
        var scratchpad: Bool?
    }

    var savedAt = Date()
    /// In tiling order.
    var windows: [Window] = []
    /// Per workspace (as a string key), its columns as indices into `windows`.
    var columns: [String: [[Int]]] = [:]
    /// Display UUID → workspace it shows. Unlike the id, a UUID stays the same when the
    /// monitor is unplugged and plugged in again.
    var displays: [String: Int]?
    /// Workspace (as a string) → UUID of the display it was moved to.
    var moved: [String: String]?
    /// Display UUID → its layout and master ratio.
    var layouts: [String: DisplayLayout]?
    /// Per workspace (as a string key), which of its `columns` are accordions.
    var accordions: [String: [Int]]?
    /// Workspaces stacked as an accordion over a tall, wide or monocle layout.
    var accordionWorkspaces: [Int]?

    struct DisplayLayout: Codable, Equatable {
        var layout: String
        var ratio: Double
    }

    /// Older states describe windows long gone.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HyperSpace", isDirectory: true)
            .appendingPathComponent("workspaces.json")
    }

    static func load(now: Date = Date()) -> WorkspaceState? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? decoder.decode(WorkspaceState.self, from: data),
              now.timeIntervalSince(state.savedAt) < maxAge else { return nil }
        return state
    }

    /// A failure (a full disk) is logged: the next start then finds older workspaces or none.
    func save() {
        let url = Self.fileURL
        do {
            let data = try Self.encoder.encode(self)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("cannot save workspaces: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Hands out saved windows to the windows found at start, each saved window once.
struct WorkspaceRestorer {
    private let windows: [WorkspaceState.Window]
    private var claimed: Set<Int> = []

    init(_ state: WorkspaceState) {
        windows = state.windows
    }

    /// The saved window this one was: same app and title, else the first unclaimed of its app.
    mutating func claim(app: String, title: String?) -> Int? {
        let candidates = windows.indices.filter { windows[$0].app == app && !claimed.contains($0) }
        guard let index = candidates.first(where: { windows[$0].title == title }) ?? candidates.first else { return nil }
        claimed.insert(index)
        return index
    }

    func window(_ index: Int) -> WorkspaceState.Window { windows[index] }

    /// Saved windows no window was found for yet (apps not reopened so far).
    var unclaimed: [WorkspaceState.Window] {
        windows.indices.filter { !claimed.contains($0) }.map { windows[$0] }
    }
}
