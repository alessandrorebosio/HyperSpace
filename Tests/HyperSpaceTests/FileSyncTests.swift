import Foundation
import Testing
@testable import HyperSpace

/// `SyncedSlice`: a settings model reloads only when its part of config.json changed.
@Suite struct SyncedSliceTests {
    private let file: [String: Any] = [
        "tiling": ["gap": 8, "floating": ["com.apple.finder"]],
        "mouse": ["reverseScroll": true],
    ]

    @Test func aNewSliceSeesItsSectionsAsChanged() {
        let slice = SyncedSlice(sections: "tiling")
        #expect(slice.changed(in: file))
        // Nothing of its own in the file: nothing to reload.
        #expect(!slice.changed(in: ["mouse": ["reverseScroll": true]]))
    }

    @Test func recordedSectionsAreNotChanged() {
        var slice = SyncedSlice(sections: "tiling")
        slice.record(file)
        #expect(!slice.changed(in: file))
    }

    @Test func otherSectionsAreIgnored() {
        var slice = SyncedSlice(sections: "tiling")
        slice.record(file)
        var edited = file
        edited["mouse"] = ["reverseScroll": false]
        edited["keyboard"] = ["remap": []]
        #expect(!slice.changed(in: edited))
    }

    @Test func aNestedEditInItsSectionIsAChange() {
        var slice = SyncedSlice(sections: "tiling", "mouse")
        slice.record(file)
        var edited = file
        edited["tiling"] = ["gap": 8, "floating": ["com.apple.finder", "com.apple.Notes"]]
        #expect(slice.changed(in: edited))
        edited = file
        edited["mouse"] = nil
        #expect(slice.changed(in: edited))
    }

    @Test func aCustomExtractWatchesOnlyItsKeys() {
        var slice = SyncedSlice { root in
            (root["tiling"] as? [String: Any])?.filter { $0.key == "floating" } ?? [:]
        }
        slice.record(file)
        var edited = file
        edited["tiling"] = ["gap": 12, "floating": ["com.apple.finder"]]
        #expect(!slice.changed(in: edited))
        edited["tiling"] = ["gap": 8, "floating": [String]()]
        #expect(slice.changed(in: edited))
    }
}

/// `assignIfChanged`: equal values are not assigned, so `@Published` does not redraw.
@Suite struct AssignIfChangedTests {
    /// Equal by `value`, told apart by identity: shows whether the property was assigned.
    private final class Box: Equatable {
        let value: Int
        init(_ value: Int) { self.value = value }
        static func == (a: Box, b: Box) -> Bool { a.value == b.value }
    }

    @Test func anEqualValueIsNotAssigned() {
        let original = Box(1)
        var property: Box? = original
        assignIfChanged(Box(1), to: &property)
        #expect(property === original)
    }

    @Test func aDifferentValueIsAssigned() {
        let replacement = Box(2)
        var property: Box? = Box(1)
        assignIfChanged(replacement, to: &property)
        #expect(property === replacement)
    }

    @Test func nilAndValueReplaceEachOther() {
        var property: Box?
        assignIfChanged(Box(3), to: &property)
        #expect(property?.value == 3)
        assignIfChanged(nil, to: &property)
        #expect(property == nil)
        assignIfChanged(nil, to: &property)
        #expect(property == nil)
    }
}
