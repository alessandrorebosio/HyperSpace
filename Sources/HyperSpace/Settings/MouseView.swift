import SwiftUI

struct MouseView: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            scrollSection
            buttonsSection
            footer
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440, alignment: .topLeading)
    }

    private var scrollSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reverse scroll wheel")
                    Text("Only mice with a wheel; trackpads and Magic Mouse keep the system direction.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.reverseScroll }, set: { model.setReverseScroll($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(6)
        } label: {
            Text("Scrolling")
        }
    }

    private var buttonsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.rules.isEmpty {
                    Text("No button mappings yet. Add one and click the mouse button you want to change.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.rules) { rule in
                            MouseRuleRow(model: model, rule: rule)
                        }
                    }
                }
                Button {
                    model.addRule()
                } label: {
                    Label("Add Button", systemImage: "plus")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Buttons")
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                Text("Click a mouse button over this window (hold modifiers to include them), then press the keys it should send. Changes apply instantly.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open config.json") { NSWorkspace.shared.open(ConfigStore.url) }
        }
        .font(.caption)
    }
}

private struct MouseRuleRow: View {
    @ObservedObject var model: MouseModel
    let rule: MouseModel.Rule

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.capturing == .button(rule.id) ? model.stopCapture() : model.startCapture(.button(rule.id))
            } label: {
                Text(model.capturing == .button(rule.id) ? "Click a mouse button here…" : (rule.button == nil ? "Button" : MouseModel.buttonLabel(rule)))
                    .frame(minWidth: 190)
                    .foregroundStyle(model.capturing == .button(rule.id) ? Color.accentColor : (rule.button == nil ? .secondary : .primary))
            }
            .buttonStyle(.bordered)

            Image(systemName: "arrow.right").foregroundStyle(.secondary)

            Menu {
                Button("Press Keys…") { model.startCapture(.action(rule.id)) }
                Divider()
                ForEach(MouseModel.presets, id: \.group) { group in
                    Menu(group.group) {
                        ForEach(group.items, id: \.action) { item in
                            Button(item.name) { model.choose(item.action, for: rule.id) }
                        }
                    }
                }
                Divider()
                Button("Disable Button") { model.disable(rule.id) }
            } label: {
                Text(model.capturing == .action(rule.id) ? "Press keys…" : (rule.action.isEmpty ? "Action" : MouseModel.actionLabel(rule.action)))
            }
            .frame(width: 220)

            Spacer()
            if let warning = model.warning(for: rule) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warning)
            }
            Button {
                model.remove(rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }
}
