import Combine
import Foundation

/// State of the Trackpad page: the edge sliders and the corners. Every change is written to
/// config.json at once; the config watcher then applies it.
final class TrackpadModel: ObservableObject, FileBackedModel {
    /// An edge of the trackpad, with its key in the file and its default.
    enum Edge: CaseIterable {
        case left, right, top, bottom

        var key: String {
            switch self {
            case .left: return "leftEdge"
            case .right: return "rightEdge"
            case .top: return "topEdge"
            case .bottom: return "bottomEdge"
            }
        }

        var title: String {
            switch self {
            case .left: return "Left edge"
            case .right: return "Right edge"
            case .top: return "Top edge"
            case .bottom: return "Bottom edge"
            }
        }

        var defaultAction: EdgeAction {
            switch self {
            case .left: return TrackpadConfig.defaultLeftEdge
            case .right: return TrackpadConfig.defaultRightEdge
            case .top: return TrackpadConfig.defaultTopEdge
            case .bottom: return TrackpadConfig.defaultBottomEdge
            }
        }

        /// The edges a finger slides along up and down; the others, sideways.
        var isVertical: Bool { self == .left || self == .right }
    }

    @Published private(set) var edgeSliders = TrackpadConfig.defaultEdgeSliders
    @Published private(set) var edges: [Edge: EdgeAction] = TrackpadModel.defaultEdges
    /// Each corner's action as written in the file (no entry: nothing).
    @Published private(set) var corners: [TrackpadCorner: String] = [:]

    private static let defaultEdges = Dictionary(uniqueKeysWithValues: Edge.allCases.map { ($0, $0.defaultAction) })

    private struct Snapshot: Equatable {
        var edgeSliders: Bool
        var edges: [Edge: EdgeAction]
        var corners: [TrackpadCorner: String]
    }

    /// The section, and the values as loaded: only what changed since is written.
    private var sync = FileSync<Snapshot>(SyncedSlice(sections: "trackpad"))
    var saveStatus: SaveStatus { sync.status }

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(config: [String: Any]) {
        load(config)
    }

    /// Nothing here is edited over time (no recording, no typing): the file always shows at once.
    func reload(from root: [String: Any]) {
        if sync.shouldReload(root, editing: false) { load(root) }
    }

    func edge(_ edge: Edge) -> EdgeAction {
        edges[edge] ?? edge.defaultAction
    }

    func setEdgeSliders(_ on: Bool) {
        guard edgeSliders != on else { return }
        edgeSliders = on
        save()
    }

    func setEdge(_ action: EdgeAction, for edge: Edge) {
        guard self.edge(edge) != action else { return }
        edges[edge] = action
        save()
    }

    /// `action`: the action's config text; "none" (or empty) clears the corner.
    func setCorner(_ action: String, for corner: TrackpadCorner) {
        let value = Self.cornerValue(action)
        guard corners[corner] != value else { return }
        corners[corner] = value
        save()
    }

    static func label(_ action: EdgeAction, vertical: Bool) -> String {
        switch action {
        case .volume: return "Volume"
        case .brightness: return "Display brightness"
        case .seek: return vertical ? "Seek (up forward)" : "Seek (arrow keys)"
        case .none: return "Nothing"
        }
    }

    static func cornerLabel(_ action: String?) -> String {
        guard let action else { return "Nothing" }
        return MouseModel.actionLabel(action)
    }

    static func cornerTitle(_ corner: TrackpadCorner) -> String {
        switch corner {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    /// A corner's action as kept: nil for nothing.
    private static func cornerValue(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.lowercased() != "none" else { return nil }
        return text
    }

    /// The corners in a file's `trackpad` section; unknown corners are left out (the config reports them).
    static func corners(in trackpad: [String: Any]) -> [TrackpadCorner: String] {
        var result: [TrackpadCorner: String] = [:]
        for (name, value) in trackpad["corners"] as? [String: Any] ?? [:] {
            if let corner = TrackpadCorner(rawValue: name), let text = cornerValue(value as? String) { result[corner] = text }
        }
        return result
    }

    private func load(_ config: [String: Any]) {
        let trackpad = ConfigWriter.section("trackpad", of: config)
        // An unknown edge (a hand-edited file) shows as its default; the config reports it.
        var newEdges: [Edge: EdgeAction] = [:]
        for edge in Edge.allCases {
            newEdges[edge] = TrackpadConfig.edge(trackpad[edge.key] as? String, default: edge.defaultAction) ?? edge.defaultAction
        }
        let on = trackpad["edgeSliders"] as? Bool ?? TrackpadConfig.defaultEdgeSliders
        let newCorners = Self.corners(in: trackpad)
        assignIfChanged(on, to: &edgeSliders)
        assignIfChanged(newEdges, to: &edges)
        assignIfChanged(newCorners, to: &corners)
        sync.didLoad(config, Snapshot(edgeSliders: on, edges: newEdges, corners: newCorners))
    }

    /// Writes the values changed since the load (a key the user never set stays out of the file).
    private func save() {
        let loaded = sync.loaded
        let current = Snapshot(edgeSliders: edgeSliders, edges: edges, corners: corners)
        sync.save(current) { root in
            ConfigWriter.edit(&root, section: "trackpad") { trackpad in
                if current.edgeSliders != loaded?.edgeSliders { trackpad["edgeSliders"] = current.edgeSliders }
                for edge in Edge.allCases where self.edge(edge) != loaded?.edges[edge] {
                    trackpad[edge.key] = self.edge(edge).rawValue
                }
                if current.corners != loaded?.corners {
                    trackpad["corners"] = current.corners.isEmpty
                        ? nil : Dictionary(uniqueKeysWithValues: current.corners.map { ($0.key.rawValue, $0.value) })
                }
            }
        }
    }
}
