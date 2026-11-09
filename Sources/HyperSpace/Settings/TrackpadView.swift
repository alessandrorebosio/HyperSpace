import SwiftUI

/// State of the Trackpad page: the edge sliders. Every change is written to config.json at
/// once; the config watcher then applies it.
final class TrackpadModel: ObservableObject {
    @Published private(set) var edgeSliders = TrackpadConfig.defaultEdgeSliders
    @Published private(set) var leftEdge = TrackpadConfig.defaultLeftEdge
    @Published private(set) var rightEdge = TrackpadConfig.defaultRightEdge
    @Published private(set) var saveError: String?

    init() {
        load()
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

    private func load() {
        let trackpad = ConfigWriter.read(section: "trackpad")
        func edge(_ key: String, _ fallback: EdgeAction) -> EdgeAction {
            (trackpad[key] as? String).flatMap { EdgeAction(configText: $0) } ?? fallback
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

/// The Trackpad page: the edge sliders.
struct TrackpadView: View {
    @ObservedObject var model: TrackpadModel

    var body: some View {
        Form {
            PageHero(page: .trackpad)

            Section {
                SwitchRow(title: "Edge sliders", detail: "Slide one finger up or down along the left or right edge.",
                          isOn: model.edgeSliders, set: model.setEdgeSliders)
                edgePicker("Left edge", selection: model.leftEdge, left: true)
                edgePicker("Right edge", selection: model.rightEdge, left: false)
            } footer: {
                SectionFooter("The pointer stays still while you slide; moving sideways, or a second finger, leaves the trackpad as usual. Brightness changes the built-in display and Apple displays.",
                              error: model.saveError)
            }
        }
        .formStyle(.grouped)
    }

    private func edgePicker(_ title: String, selection: EdgeAction, left: Bool) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: { model.setEdge($0, left: left) })) {
            ForEach(EdgeAction.allCases, id: \.self) { action in
                Text(TrackpadModel.label(action)).tag(action)
            }
        }
        .disabled(!model.edgeSliders)
    }
}
