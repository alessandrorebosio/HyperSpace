import SwiftUI

/// The Tiling page: on/off in the hero, the layout, spacing, focus and accordion.
struct TilingView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHero(page: .tiling) {
                Toggle("Tile windows", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(model.enabled ? "Tiling is on" : "Tiling is off: windows stay where you put them")
                    .accessibilityLabel("Tile windows")
            }
            PermissionNotice()

            Section {
                LayoutChooser(selection: model.layout, gap: model.gap, padding: model.padding,
                              peek: model.accordionPadding) { model.setLayout($0) }
            } header: {
                Text("Layout")
            } footer: {
                SectionFooter("For every display, until you pick another layout from the menu bar or with a shortcut.")
            }
            .disabled(!model.enabled)

            Section {
                SliderRow(title: "Gap between windows",
                          value: model.gap, range: TilingModel.spacingRange, step: 2,
                          onChange: { model.setGap($0) }, onCommit: model.commitSpacing)
                SliderRow(title: "Margin around the screen",
                          value: model.padding, range: TilingModel.spacingRange, step: 2,
                          onChange: { model.setPadding($0) }, onCommit: model.commitSpacing)
            } header: {
                Text("Spacing")
            } footer: {
                SectionFooter("Windows stay inside the visible area, clear of the menu bar and the Dock.",
                              error: model.saveError)
            }
            .disabled(!model.enabled)

            Section {
                SliderRow(title: "Visible edges",
                          value: model.accordionPadding, range: TilingModel.accordionRange, step: 5,
                          onChange: { model.setAccordionPadding($0) }, onCommit: model.commitSpacing)
                AccordionPreview(peek: model.accordionPadding)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } header: {
                Text("Accordion")
            } footer: {
                SectionFooter("How much of the windows behind the front one shows at each side, in the Accordion layout and in workspaces stacked with the accordion shortcut.")
            }
            .disabled(!model.enabled)

            Section {
                Toggle(isOn: Binding(get: { model.mouseFollowsFocus }, set: { model.setMouseFollowsFocus($0) })) {
                    RowLabel("Pointer follows focus", detail: "When the focus moves to another display, the pointer goes there too.")
                }
            } header: {
                Text("Focus")
            }
            .disabled(!model.enabled)
        }
        .formStyle(.grouped)
    }
}

/// Shown on the window pages while tiling is off: the settings are kept but do nothing.
struct TilingOffNotice: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        if !model.enabled {
            Section {
                NoticeRow(symbol: "pause.fill", color: .gray, title: "Tiling is off",
                          detail: "Windows stay where you put them. These settings are kept and apply as soon as it is on.",
                          button: "Turn On") { model.setEnabled(true) }
            }
        }
    }
}

/// Three windows as an accordion with the chosen edges, drawn to scale (a 1000 pt wide area).
private struct AccordionPreview: View {
    let peek: Int

    var body: some View {
        Canvas { context, size in
            let area = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            let scale = area.width / 1000
            let frames = Layout.accordion(count: 3, focused: 1, in: area, peek: CGFloat(peek) * scale)
            for index in [0, 2, 1] {
                let main = index == 1
                let frame = main ? frames[index] : frames[index].insetBy(dx: 0, dy: 6)
                let card = Path(roundedRect: frame, cornerRadius: 7, style: .continuous)
                var shadowed = context
                if main { shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 4, y: 1.5)) }
                shadowed.fill(card, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.fill(card, with: .color(Color.accentColor.opacity(main ? 0.85 : 0.35)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .frame(maxWidth: 360)
        .accessibilityLabel("Accordion preview with \(peek) point edges")
    }
}

/// The layouts as thumbnails; the gap and margin are drawn to scale with the settings. In a narrow
/// window the thumbnails shrink, and below that they wrap onto more lines.
private struct LayoutChooser: View {
    let selection: LayoutKind
    let gap: Int
    let padding: Int
    let peek: Int
    let onSelect: (LayoutKind) -> Void

    // Like the Appearance picker of System Settings: no glass of its own inside the form (the
    // grouped form already sits on the system's Liquid Glass; glass is for floating controls).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { options(compact: false) }
            HStack(spacing: 6) { options(compact: true) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) { options(compact: true) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func options(compact: Bool) -> some View {
        ForEach(LayoutKind.allCases, id: \.self) { kind in
            LayoutOption(kind: kind, selected: kind == selection, compact: compact, gap: gap, padding: padding, peek: peek) {
                onSelect(kind)
            }
            .help(Self.help(kind))
        }
    }

    private static func help(_ kind: LayoutKind) -> String {
        switch kind {
        case .tall: return "Main window on the left, the others stacked on the right"
        case .wide: return "Main window on top, the others side by side below"
        case .columns: return "One column per window"
        case .monocle: return "Every window full screen, one above the other"
        case .accordion: return "Windows stacked on top of each other, the ones behind peeking out at the sides"
        }
    }
}

/// One layout: its picture and name on a softly filled tile, ringed with the accent color when chosen.
private struct LayoutOption: View {
    let kind: LayoutKind
    let selected: Bool
    let compact: Bool
    let gap: Int
    let padding: Int
    let peek: Int
    let action: () -> Void

    private static let corner: CGFloat = 16

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                LayoutThumbnail(kind: kind, gap: gap, padding: padding, peek: peek, selected: selected, compact: compact)
                    .frame(width: compact ? 60 : 84, height: compact ? 40 : 54)
                Text(kind.rawValue.capitalized)
                    .font((compact ? Font.caption : Font.callout).weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(OptionBackground(selected: selected, corner: Self.corner))
        .accessibilityLabel(kind.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OptionBackground: ViewModifier {
    let selected: Bool
    let corner: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .background(shape.fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
    }
}

/// A small picture of a display with the layout's windows on it. The display and the windows
/// share concentric rounded corners; the main (or focused) window is filled with the accent
/// color, the others are lighter, gray when the layout is not the chosen one. Gap and margin
/// are drawn to scale, exaggerated so a few points still show; the accordion's edges are
/// widened enough to read, and its windows behind are drawn shorter, as a stack.
private struct LayoutThumbnail: View {
    let kind: LayoutKind
    let gap: Int
    let padding: Int
    let peek: Int
    let selected: Bool
    /// The smaller thumbnail of a narrow window: gap and margin are drawn smaller too.
    let compact: Bool

    var body: some View {
        let scale: CGFloat = compact ? 0.1 : 0.15
        let inset = padding == 0 ? 0 : max(1.5, CGFloat(padding) * scale)
        let spacing = gap == 0 ? 0 : max(2.5, CGFloat(gap) * scale)
        let screenCorner: CGFloat = 9
        Canvas { context, size in
            let margin = 4 + inset
            let area = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            let count = kind == .monocle ? 1 : 3
            let frames = Layout.frames(kind, weights: Array(repeating: 1, count: count), in: area, gap: spacing, ratio: TilingConfig.defaultMasterRatio,
                                       focused: 1, peek: max(compact ? 8 : 12, CGFloat(peek) * 0.35))
            let order = kind == .accordion ? [0, 2, 1] : Array(frames.indices)
            let corner = max(2.5, screenCorner - margin)
            let tint = selected ? Color.accentColor : Color.secondary
            for index in order {
                let main = kind == .accordion ? index == 1 : index == 0
                let frame = kind == .accordion && !main ? frames[index].insetBy(dx: 0, dy: 5) : frames[index]
                let card = Path(roundedRect: frame, cornerRadius: corner, style: .continuous)
                if kind == .accordion {
                    // Opaque first, so the windows behind do not show through the front one.
                    var shadowed = context
                    if main { shadowed.addFilter(.shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)) }
                    shadowed.fill(card, with: .color(Color(nsColor: .windowBackgroundColor)))
                }
                context.fill(card, with: .color(tint.opacity(main ? 0.85 : 0.35)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: screenCorner, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }
}
