import Combine
import Foundation

/// State of the Trackpad page: the edge sliders. Every change is written to config.json at
/// once; the config watcher then applies it.
final class TrackpadModel: ObservableObject {
    @Published private(set) var edgeSliders = TrackpadConfig.defaultEdgeSliders
    @Published private(set) var leftEdge = TrackpadConfig.defaultLeftEdge
    @Published private(set) var rightEdge = TrackpadConfig.defaultRightEdge
    @Published private(set) var saveError: String?

    /// `config`: the file as `ConfigWriter.read()` returns it.
    init(config: [String: Any]) {
        load(config)
    }

    func setEdgeSliders(_ on: Bool) {
        edgeSliders = on
        save()
    }

    func setEdge(_ action: EdgeAction, left: Bool) {
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
        edgeSliders = trackpad["edgeSliders"] as? Bool ?? TrackpadConfig.defaultEdgeSliders
        leftEdge = edge("leftEdge", TrackpadConfig.defaultLeftEdge)
        rightEdge = edge("rightEdge", TrackpadConfig.defaultRightEdge)
    }

    private func save() {
        saveError = ConfigWriter.save(section: "trackpad") { trackpad in
            trackpad["edgeSliders"] = edgeSliders
            trackpad["leftEdge"] = leftEdge.rawValue
            trackpad["rightEdge"] = rightEdge.rawValue
        }
    }
}
