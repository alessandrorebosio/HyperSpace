import SwiftUI

/// The Trackpad page: the edge sliders and the corners.
struct TrackpadView: View {
    @ObservedObject var model: TrackpadModel

    var body: some View {
        Form {
            PageHero(page: .trackpad)
            PermissionNotice(detail: "The sliders and corners work, but the pointer is held still and a corner's tap kept from clicking only once HyperSpace is allowed in \(Wording.accessibilityPane).")
            SaveErrorNotice(status: model.saveStatus)

            Section {
                SwitchRow(title: "Edge sliders", detail: "Slide one finger along an edge: up and down on the sides, sideways on the top and bottom.",
                          isOn: model.edgeSliders, set: model.setEdgeSliders)
                ForEach(TrackpadModel.Edge.allCases, id: \.self) { edge in
                    edgePicker(edge)
                }
            } header: {
                Text("Edges")
            } footer: {
                SectionFooter("The pointer stays still while you slide; moving across the edge, a second finger or pressing the trackpad leaves it as usual. Seek sends the arrow keys: videos jump back and forward, editors move the playhead. Brightness changes the built-in display and Apple displays.")
            }

            Section {
                ForEach(TrackpadCorner.allCases, id: \.self) { corner in
                    SettingRow(title: TrackpadModel.cornerTitle(corner)) {
                        // The ready-made actions of the mouse buttons, or nothing. Built again
                        // only when the corner's action changes.
                        GroupedChoiceMenu(id: corner, title: TrackpadModel.cornerLabel(model.corners[corner]),
                                          help: "Action of a double tap in the \(TrackpadModel.cornerTitle(corner).lowercased()) corner",
                                          groups: MouseModel.presetGroups, first: (label: "Nothing", value: "none")) {
                            model.setCorner($0, for: corner)
                        }
                        .equatable()
                    }
                }
            } header: {
                Text("Corners")
            } footer: {
                SectionFooter("Double-tap a corner with one finger to run its action. A tap or click in a corner with an action does nothing else.")
            }
        }
        .formStyle(.grouped)
    }

    /// A row like every other setting's (`SettingRow`), its menu sized to its choice.
    private func edgePicker(_ edge: TrackpadModel.Edge) -> some View {
        SettingRow(title: edge.title) {
            Picker(edge.title, selection: Binding(get: { model.edge(edge) }, set: { model.setEdge($0, for: edge) })) {
                ForEach(EdgeAction.allCases, id: \.self) { action in
                    Text(TrackpadModel.label(action, vertical: edge.isVertical)).tag(action)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!model.edgeSliders)
    }
}
