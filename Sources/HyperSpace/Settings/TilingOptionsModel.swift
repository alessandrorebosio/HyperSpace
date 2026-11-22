import Combine
import CoreGraphics
import Foundation

/// State of the Tiling page: on or off, the layout, the spacing, the accordion's edges, the
/// pointer. The three other window pages read `enabled` for their *Tiling is off* notice.
/// Changes go to the file through the shared `TilingModel`.
final class TilingOptionsModel: ObservableObject {
    /// The options as the file takes them: what is compared to write only a change.
    struct Values: Equatable {
        var enabled: Bool
        var layout: LayoutKind
        var gap, padding, accordionPadding: Int
        var mouseFollowsFocus: Bool
    }

    /// Where every option starts: the defaults of the config itself.
    private typealias Defaults = TilingConfig

    @Published private(set) var enabled = Defaults.defaultEnabled
    @Published private(set) var layout = Defaults.defaultLayout
    @Published private(set) var gap = Int(Defaults.defaultGap)
    @Published private(set) var padding = Int(Defaults.defaultPadding)
    @Published private(set) var mouseFollowsFocus = Defaults.defaultMouseFollowsFocus
    @Published private(set) var accordionPadding = Int(Defaults.defaultAccordionPadding)

    /// The writer the four window pages share.
    weak var store: TilingModel?
    /// A slider value changed without a drag (arrow keys, VoiceOver) is saved shortly after.
    private let spacingSave = Debouncer(delay: 0.6)
    /// A slider is being dragged: saved on release.
    private var sliderHeld = false

    var values: Values {
        Values(enabled: enabled, layout: layout, gap: gap, padding: padding, accordionPadding: accordionPadding,
               mouseFollowsFocus: mouseFollowsFocus)
    }

    /// A slider is being moved: a reload waits for it.
    var isAdjusting: Bool { spacingSave.isPending || sliderHeld }

    /// The window closes with a slider still held: its value is saved as it is.
    func releaseSlider() {
        sliderHeld = false
    }

    /// A save is about to write the values shown: no later one is needed.
    func prepareToSave() {
        spacingSave.cancel()
    }

    private func edit(_ change: () -> Void) {
        guard let store else { return change() }
        store.edit(change)
    }

    // MARK: - Editing

    func setEnabled(_ on: Bool) { guard enabled != on else { return }; edit { enabled = on } }
    func setLayout(_ kind: LayoutKind) { guard layout != kind else { return }; edit { layout = kind } }
    func setMouseFollowsFocus(_ on: Bool) { guard mouseFollowsFocus != on else { return }; edit { mouseFollowsFocus = on } }

    /// The slider setters show the value at once; it is saved when the slider is released, or
    /// shortly after a change made without dragging. A drag sends the same rounded value many
    /// times: only a change is published.
    func setGap(_ value: Int) { setSpacing(value.clamped(to: TilingModel.spacingRange), \.gap) }
    func setPadding(_ value: Int) { setSpacing(value.clamped(to: TilingModel.spacingRange), \.padding) }
    func setAccordionPadding(_ value: Int) { setSpacing(value.clamped(to: TilingModel.accordionRange), \.accordionPadding) }

    private func setSpacing(_ value: Int, _ property: ReferenceWritableKeyPath<TilingOptionsModel, Int>) {
        guard self[keyPath: property] != value else { return }
        self[keyPath: property] = value
        if !sliderHeld { spacingSave.schedule { [weak self] in self?.commitSpacing() } }
    }

    /// A slider is grabbed or released: released, its value is saved (the config reload
    /// retiles once).
    func sliderEditing(_ editing: Bool) {
        sliderHeld = editing
        if editing {
            spacingSave.cancel()
        } else {
            commitSpacing()
        }
    }

    private func commitSpacing() {
        // The values shown, put back after a reload that was waiting for the slider.
        let shown = (gap: self.gap, padding: self.padding, accordion: self.accordionPadding)
        edit {
            gap = shown.gap
            padding = shown.padding
            accordionPadding = shown.accordion
        }
    }

    // MARK: - Persistence

    /// Shows the `tiling` section of the file. The config clamps the numbers too: what a
    /// hand-edited file holds shows as it will apply.
    func load(_ tiling: [String: Any]) {
        func number(_ key: String, _ range: ClosedRange<CGFloat>, _ fallback: CGFloat) -> Int {
            Int(TilingConfig.value((tiling[key] as? NSNumber)?.doubleValue, range, fallback))
        }
        assignIfChanged(tiling["enabled"] as? Bool ?? Defaults.defaultEnabled, to: &enabled)
        assignIfChanged((tiling["layout"] as? String).flatMap { LayoutKind(configText: $0) } ?? Defaults.defaultLayout, to: &layout)
        assignIfChanged(number("gap", Defaults.spacingRange, Defaults.defaultGap), to: &gap)
        assignIfChanged(number("padding", Defaults.spacingRange, Defaults.defaultPadding), to: &padding)
        assignIfChanged(number("accordionPadding", Defaults.accordionPaddingRange, Defaults.defaultAccordionPadding), to: &accordionPadding)
        assignIfChanged(tiling["mouseFollowsFocus"] as? Bool ?? Defaults.defaultMouseFollowsFocus, to: &mouseFollowsFocus)
    }

    /// The options that changed since the load (`old`): one never changed stays out of the
    /// file, or as it is written there.
    static func write(_ new: Values, to tiling: inout [String: Any], since old: Values?) {
        tiling.write("enabled", new.enabled, since: old?.enabled)
        tiling.write("layout", new.layout.rawValue, since: old?.layout.rawValue)
        tiling.write("gap", new.gap, since: old?.gap)
        tiling.write("padding", new.padding, since: old?.padding)
        tiling.write("mouseFollowsFocus", new.mouseFollowsFocus, since: old?.mouseFollowsFocus)
        tiling.write("accordionPadding", new.accordionPadding, since: old?.accordionPadding)
    }
}
