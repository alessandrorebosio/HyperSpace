import AppKit
import SwiftUI

/// A panel in the middle of the display under the pointer that shows every workspace with
/// the apps in it and the shortcut that shows it, while the overview key is held.
/// It never takes the focus or the clicks: the app underneath keeps both.
final class WorkspaceOverview {
    struct Host {
        var workspaces: () -> [WorkspaceSummary]
        var focused: () -> Int?
        /// Workspace index → the shortcut that shows it, as written in the config.
        var switchKeys: () -> [Int: String]
    }

    private let host: Host
    private var panel: NSPanel?
    private var hosting: NSHostingView<OverviewView>?
    /// Whether the panel should be on screen: a fade out finishing after a new show leaves it.
    private var wanted = false
    /// A click anywhere closes the panel too, in case the key up never reaches the tap.
    private var clickMonitor: Any?

    init(host: Host) {
        self.host = host
    }

    private var isVisible: Bool { panel?.isVisible == true }

    /// Shown until hidden: by the key up of the held key, a click, or (from a mouse button) a toggle.
    func show() {
        guard let area = Self.screenArea(), let view = makeView(maxWidth: area.width - 80) else { return }
        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
            self.hosting = hosting
        }
        place(panel, in: area)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // Also brings back a panel still fading out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        wanted = true
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
    }

    func hide() {
        wanted = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Shown again meanwhile: stays.
            guard let self, !self.wanted else { return }
            panel.orderOut(nil)
        })
    }

    func toggle() {
        if wanted { hide() } else { show() }
    }

    /// The workspaces changed (a switch while the overview is open): drawn again.
    func refresh() {
        guard isVisible, let panel, let area = Self.screenArea(),
              let view = makeView(maxWidth: area.width - 80) else { return }
        hosting?.rootView = view
        place(panel, in: area)
    }

    /// The view with everything it shows, sized for `maxWidth`: the root view is set once per
    /// show or refresh (each assignment makes the hosting view update the whole tree).
    private func makeView(maxWidth: CGFloat) -> OverviewView? {
        let workspaces = host.workspaces()
        guard !workspaces.isEmpty else { return nil }
        let keys = host.switchKeys()
        return OverviewView(
            cards: workspaces.map { OverviewView.Card($0, keys: keys[$0.index].map(RemapTarget.label)) },
            focused: host.focused(),
            maxWidth: maxWidth
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.panel = panel
        return panel
    }

    /// The visible area of the display under the pointer (AppKit coordinates).
    private static func screenArea() -> NSRect? {
        let mouse = NSEvent.mouseLocation
        return (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
    }

    /// Centered in `area`, never larger than it.
    private func place(_ panel: NSPanel, in area: NSRect) {
        guard let hosting else { return }
        let size = hosting.fittingSize
        let width = min(size.width, area.width - 40)
        let height = min(size.height, area.height - 40)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height),
                       display: true)
    }
}

struct OverviewView: View {
    struct Card: Identifiable {
        let summary: WorkspaceSummary
        let keys: String?
        /// `summary.apps`, worked out once.
        let apps: [WorkspaceSummary.App]
        var id: Int { summary.index }

        init(_ summary: WorkspaceSummary, keys: String?) {
            self.summary = summary
            self.keys = keys
            apps = summary.apps
        }
    }

    static let cardWidth: CGFloat = 210
    static let spacing: CGFloat = 12
    static let maxApps = 6

    let cards: [Card]
    let focused: Int?
    let maxWidth: CGFloat

    private var columns: Int {
        // n cards take n × width + (n - 1) × spacing, plus the panel's padding on both sides.
        let fit = Int((maxWidth - Self.spacing) / (Self.cardWidth + Self.spacing))
        return max(1, min(4, fit, cards.count))
    }

    var body: some View {
        let rows = stride(from: 0, to: cards.count, by: columns).map { Array(cards[$0..<min($0 + columns, cards.count)]) }
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(rows[row]) { card in
                        CardView(card: card, focused: card.summary.index == focused)
                    }
                }
            }
        }
        .padding(Self.spacing + 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }

    private struct CardView: View {
        let card: Card
        let focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(card.summary.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if card.summary.display != nil {
                        Image(systemName: "display")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let keys = card.keys {
                        Text(keys)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if card.apps.isEmpty {
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(card.apps.prefix(OverviewView.maxApps)) { app in
                            HStack(spacing: 7) {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "macwindow").frame(width: 18, height: 18)
                                }
                                Text(app.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                if app.windows > 1 {
                                    Text("×\(app.windows)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if card.apps.count > OverviewView.maxApps {
                            Text("+\(card.apps.count - OverviewView.maxApps) more")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: OverviewView.cardWidth, alignment: .topLeading)
            .frame(minHeight: 70, alignment: .topLeading)
            .background(.primary.opacity(focused ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2))
            .opacity(card.apps.isEmpty && !focused ? 0.6 : 1)
        }
    }
}
