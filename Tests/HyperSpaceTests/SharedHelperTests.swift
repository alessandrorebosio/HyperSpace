import AppKit
import Testing
@testable import HyperSpace

/// The helpers the config and the settings pages share, so both read a file the same way.
@Suite struct SharedHelperTests {
    @Test func numbersAreClampedOrDefaulted() {
        #expect(TilingConfig.value(nil, TilingConfig.spacingRange, 8) == 8)
        #expect(TilingConfig.value(100, TilingConfig.spacingRange, 8) == 64)
        #expect(TilingConfig.value(-3, TilingConfig.spacingRange, 8) == 0)
        #expect(TilingConfig.value(12, TilingConfig.spacingRange, 8) == 12)
    }

    @Test func edgesDefaultWhenMissingAndFailWhenUnknown() throws {
        #expect(TrackpadConfig.edge(nil, default: .volume) == .volume)
        #expect(TrackpadConfig.edge("", default: .volume) == .volume)
        #expect(TrackpadConfig.edge("Brightness", default: .volume) == .brightness)
        #expect(TrackpadConfig.edge("loudness", default: .volume) == nil)
        #expect(throws: ConfigError.self) { try config(#"{ "trackpad": { "leftEdge": "loudness" } }"#) }
    }

    @Test func hyperKeyComesFirst() {
        let remaps = [RawConfig.Remap(from: "a", to: "b", keyboard: "builtin")]
        #expect(RawConfig.Remap.withHyperKey(remaps, hyperKey: nil).map(\.from) == ["a"])
        #expect(RawConfig.Remap.withHyperKey(remaps, hyperKey: "").map(\.from) == ["a"])
        let withHyper = RawConfig.Remap.withHyperKey(remaps, hyperKey: "caps_lock")
        #expect(withHyper.map(\.from) == ["caps_lock", "a"])
        #expect(withHyper[0].to == "hyper" && withHyper[0].keyboard == nil)
    }

    @Test func ratioStaysInRange() {
        var state = ScreenState(layout: .tall, ratio: 0.55)
        state.adjustRatio(by: 0.05)
        #expect(abs(state.ratio - 0.6) < 0.0001)
        state.adjustRatio(by: 1)
        #expect(state.ratio == TilingConfig.ratioRange.upperBound)
        state.adjustRatio(by: -2)
        #expect(state.ratio == TilingConfig.ratioRange.lowerBound)
    }

    @Test func summaryListsEachAppOnceInOrder() {
        let windows = ["Safari", "Terminal", "Safari", "Notes", "Safari"].map {
            WorkspaceSummary.Window(app: $0, title: nil, icon: nil)
        }
        let summary = WorkspaceSummary(index: 0, name: "1", display: nil, windows: windows)
        #expect(summary.apps.map(\.name) == ["Safari", "Terminal", "Notes"])
        #expect(summary.apps.map(\.windows) == [3, 1, 1])
    }

    @Test func workspaceNamesFallBackToTheirNumber() {
        #expect(TilingConfig.workspaceName(nil, at: 2) == "3")
        #expect(TilingConfig.workspaceName("", at: 0) == "1")
        #expect(TilingConfig.workspaceName("Web", at: 0) == "Web")
    }
}
