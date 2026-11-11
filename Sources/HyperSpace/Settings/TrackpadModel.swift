import Combine
import Foundation

/// State of the Trackpad page: the edge sliders. Every change is written to config.json at
/// once; the config watcher then applies it.
final class TrackpadModel: ObservableObject, FileBackedModel {
    @Published private(set) var edgeSliders = TrackpadConfig.defaultEdgeSliders
    @Published private(set) var leftEdge = TrackpadConfig.defaultLeftEdge
    @Published private(set) var rightEdge = TrackpadConfig.defaultRightEdge
    @Published private(set) var saveError: String?

    private var synced = SyncedSlice(sections: "trackpad")
    /// The values as loaded: only what changed since is written.
    private var loaded: (edgeSliders: Bool, left: EdgeAction, right: EdgeAction)?

    /// `config`: the file as `ConfigWriter.read()` returns it.
    init(config: [String: Any]) {
        load(config)
    }

    func reload(from root: [String: Any]) {
        if synced.changed(in: root) { load(root) }
    }

    func setEdgeSliders(_ on: Bool) {
        guard edgeSliders != on else { return }
        edgeSliders = on
        save()
    }

    func setEdge(_ action: EdgeAction, left: Bool) {
        guard (left ? leftEdge : rightEdge) != action else { return }
        if left { leftEdge = action } else { rightEdge = action }
        save()
    }

    static func label(_ action: EdgeAction) -> String {
        switch action {
        case .volume: return "Volume"
        case .brightness: return "Display brightness"
        case .none: return "Nothing"
        }
    }

    private func load(_ config: [String: Any]) {
        let trackpad = ConfigWriter.section("trackpad", of: config)
        // An unknown edge (a hand-edited file) shows as its default; the config reports it.
        func edge(_ key: String, _ fallback: EdgeAction) -> EdgeAction {
            TrackpadConfig.edge(trackpad[key] as? String, default: fallback) ?? fallback
        }
        let on = trackpad["edgeSliders"] as? Bool ?? TrackpadConfig.defaultEdgeSliders
        let left = edge("leftEdge", TrackpadConfig.defaultLeftEdge)
        let right = edge("rightEdge", TrackpadConfig.defaultRightEdge)
        if edgeSliders != on { edgeSliders = on }
        if leftEdge != left { leftEdge = left }
        if rightEdge != right { rightEdge = right }
        loaded = (on, left, right)
        synced.record(config)
    }

    /// Writes the values changed since the load (a key the user never set stays out of the file).
    private func save() {
        let error = ConfigWriter.save(recording: &synced) { root in
            ConfigWriter.edit(&root, section: "trackpad") { trackpad in
                if edgeSliders != loaded?.edgeSliders { trackpad["edgeSliders"] = edgeSliders }
                if leftEdge != loaded?.left { trackpad["leftEdge"] = leftEdge.rawValue }
                if rightEdge != loaded?.right { trackpad["rightEdge"] = rightEdge.rawValue }
            }
        }
        if error == nil { loaded = (edgeSliders, leftEdge, rightEdge) }
        Optional.assignChange(error, to: &saveError)
    }
}
