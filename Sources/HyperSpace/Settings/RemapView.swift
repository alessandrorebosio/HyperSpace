import SwiftUI

struct RemapView: View {
    @ObservedObject var model: RemapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            keyboardsSection
            remapSection
            footer
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440, alignment: .topLeading)
    }

    private var keyboardsSection: some View {
        GroupBox {
            HStack(spacing: 16) {
                if model.keyboards.isEmpty {
                    Text("No keyboards found").foregroundStyle(.secondary)
                }
                ForEach(model.keyboards, id: \.self) { keyboard in
                    Label(keyboard.product.isEmpty ? "Keyboard" : keyboard.product,
                          systemImage: keyboard.builtIn ? "laptopcomputer" : "keyboard")
                }
                Spacer()
            }
            .padding(6)
        } label: {
            Text("Connected keyboards")
        }
    }

    private var remapSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.rules.isEmpty {
                    Text("No remaps yet. Add one and press the key you want to change.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.rules) { rule in
                            RuleRow(model: model, rule: rule)
                        }
                    }
                }
                Button {
                    model.addRule()
                } label: {
                    Label("Add Remap", systemImage: "plus")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Remaps")
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                Text("Click a field and press keys on any keyboard. For a combination hold the keys together (e.g. ⇧⌃⌥) and release. Changes apply instantly.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open config.json") { NSWorkspace.shared.open(ConfigStore.url) }
        }
        .font(.caption)
    }
}

private struct RuleRow: View {
    @ObservedObject var model: RemapModel
    let rule: RemapModel.Rule

    var body: some View {
        HStack(spacing: 10) {
            KeyField(name: rule.from.isEmpty ? "" : KeyInfo.label(for: rule.from), placeholder: "Key",
                     capturing: model.capturing == .from(rule.id)) {
                model.capturing == .from(rule.id) ? model.stopCapture() : model.startCapture(.from(rule.id))
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            targetMenu
            Picker("", selection: Binding(get: { rule.keyboard }, set: { model.setKeyboard($0, for: rule.id) })) {
                ForEach(model.keyboardOptions(for: rule), id: \.self) { option in
                    Text(model.keyboardLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 160)
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

    /// The target is captured from the keyboard, built as a combination, or picked
    /// from every known key (including ones no keyboard has: media, F21–F24, None).
    private var targetMenu: some View {
        Menu {
            Button("Press Keys…") { model.startCapture(.to(rule.id)) }
            Divider()
            ForEach(KeyCodes.groups, id: \.title) { group in
                Menu(group.title) {
                    ForEach(group.keys, id: \.name) { key in
                        Button(key.label) { model.setTarget(key.name, for: rule.id) }
                    }
                }
            }
        } label: {
            Text(model.capturing == .to(rule.id)
                 ? (model.capturePreview.isEmpty ? "Press keys…" : "\(model.capturePreview) …")
                 : (rule.to.isEmpty ? "Target" : RemapTarget.label(rule.to)))
        }
        .frame(width: 190)
    }
}

/// A button showing a key name; while capturing it invites a key press.
private struct KeyField: View {
    let name: String
    let placeholder: String
    let capturing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(capturing ? "Press a key…" : (name.isEmpty ? placeholder : name))
                .frame(minWidth: 130)
                .foregroundStyle(capturing ? Color.accentColor : (name.isEmpty ? .secondary : .primary))
        }
        .buttonStyle(.bordered)
    }
}
