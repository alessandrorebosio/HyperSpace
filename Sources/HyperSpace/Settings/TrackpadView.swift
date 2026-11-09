import SwiftUI

/// The Trackpad page: the edge sliders.
struct TrackpadView: View {
    @ObservedObject var model: TrackpadModel

    var body: some View {
        Form {
            PageHero(page: .trackpad)
            PermissionNotice(detail: "The sliders work, but the pointer is held still while you slide only once HyperSpace is allowed in Privacy & Security → Accessibility.")

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
