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

    struct Snapshot: Equatable {
        var edgeSliders: Bool
        var edges: [Edge: EdgeAction]
        var corners: [TrackpadCorner: String]
    }

    /// The section, and the values as loaded: only what changed since is written.
    var sync = FileSync<Snapshot>(SyncedSlice(sections: "trackpad"))

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(config: [String: Any]) {
        load(config)
    }

    // Nothing here is edited over time (no recording, no typing): the file always shows at once
    // (`isEditing` stays false).

    func edge(_ edge: Edge) -> EdgeAction {
        edges[edge] ?? edge.defaultAction
    }

    func setEdgeSliders(_ on: Bool) {
        guard edgeSliders != on else { return }
        edit { edgeSliders = on }
    }

    func setEdge(_ action: EdgeAction, for edge: Edge) {
        guard self.edge(edge) != action else { return }
        edit { edges[edge] = action }
    }

    /// `action`: the action's config text; "none" (or empty) clears the corner.
    func setCorner(_ action: String, for corner: TrackpadCorner) {
        let value = Self.cornerValue(action)
        guard corners[corner] != value else { return }
        edit { corners[corner] = value }
    }

    static func label(_ action: EdgeAction, vertical: Bool) -> String {
        switch action {
        case .volume: return "Volume"
        case .brightness: return "Display brightness"
        case .seek: return vertical ? "Seek (up is forward)" : "Seek (right is forward)"
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

    func load(_ config: [String: Any]) {
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
    func save() {
        let loaded = sync.loaded
        let current = Snapshot(edgeSliders: edgeSliders, edges: edges, corners: corners)
        sync.save(current) { root in
            ConfigWriter.amend(&root, section: "trackpad") { trackpad in
                trackpad.write("edgeSliders", current.edgeSliders, since: loaded?.edgeSliders)
                for edge in Edge.allCases {
                    trackpad.write(edge.key, self.edge(edge).rawValue, since: loaded?.edges[edge]?.rawValue)
                }
                if current.corners != loaded?.corners {
                    trackpad["corners"] = current.corners.isEmpty
                        ? nil : Dictionary(uniqueKeysWithValues: current.corners.map { ($0.key.rawValue, $0.value) })
                }
            }
        }
    }
}
