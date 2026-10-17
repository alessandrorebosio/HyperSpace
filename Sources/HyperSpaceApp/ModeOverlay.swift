import AppKit
import HyperSpaceCore

/// `show-mode-bindings`: while a binding mode other than main is on, its keys and what they
/// do, in a panel at the bottom of the display under the pointer; `show-bindings-on-hold`:
/// the same for the main bindings of the modifiers held. It never takes the focus
/// or the clicks, so the mode's keys keep going where they went.
@MainActor
final class ModeOverlay {
    private var panel: NSPanel?

    /// Shows `bindings` under `title` (`mode service`, or the modifiers held for
    /// `show-bindings-on-hold`), or hides the panel when nil.
    func show(_ title: String, _ bindings: [WMSettings.BindingText]?) {
        guard let bindings else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = panel.contentView!.subviews[0] as! NSTextField
        content.attributedStringValue = text(title, bindings)
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let frame = NSRect(x: visible.midX - size.width / 2 - 16, y: visible.minY + 60, width: size.width + 32, height: size.height + 24)
        panel.setFrame(frame.integral, display: true)
        content.frame = NSRect(x: 16, y: 12, width: size.width, height: size.height)
        panel.orderFrontRegardless()
    }

    private func text(_ title: String, _ bindings: [WMSettings.BindingText]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let width = bindings.map { ($0.key as NSString).size(withAttributes: [.font: bold]).width }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: ceil(width) + 16)]
        paragraph.lineSpacing = 2
        let text = NSMutableAttributedString(string: "\(title)\n", attributes: [.font: bold, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        for (index, binding) in bindings.enumerated() {
            text.append(NSAttributedString(string: binding.key, attributes: [.font: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
            let line = "\t" + binding.commands + (index < bindings.count - 1 ? "\n" : "")
            text.append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        if bindings.isEmpty { text.append(NSAttributedString(string: "no bindings", attributes: [.font: font, .foregroundColor: NSColor.labelColor])) }
        return text
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 0
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}
