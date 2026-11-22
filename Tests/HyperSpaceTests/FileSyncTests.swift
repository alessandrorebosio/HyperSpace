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

/// What a model does when the file is loaded after one of its saves failed.
@Suite struct FailedSaveTests {
    private let file: [String: Any] = ["mouse": ["reverseScroll": false]]

    private func loaded() -> FileSync<Bool> {
        var sync = FileSync<Bool>(SyncedSlice(sections: "mouse"))
        sync.didLoad(file, false)
        return sync
    }

    /// The file parses again and the model's part is as it read it: the change is saved again.
    @Test func theSaveIsRetriedWhenTheFileIsUnchanged() {
        var sync = loaded()
        sync.didSave(true, error: ConfigWriter.SyntaxError.message)
        #expect(sync.loaded == false)
        #expect(sync.status.problem?.title == "Changes not saved")
        #expect(sync.fileLoaded(file, editing: false) == .retrySave)
        // The syntax error itself is over; the retry reports its own result.
        #expect(sync.status.error == nil)
        // Also while a shortcut is being recorded: a save never waits for that.
        #expect(sync.fileLoaded(file, editing: true) == .retrySave)
    }

    /// The model's part changed in the file meanwhile: the file wins, nothing stale is written over it.
    @Test func theFileWinsWhenItChangedToo() {
        var sync = loaded()
        sync.didSave(true, error: "disk full")
        let edited: [String: Any] = ["mouse": ["reverseScroll": false, "buttons": [["button": 3, "action": "none"]]]]
        #expect(sync.fileLoaded(edited, editing: false) == .reload)
        sync.didLoad(edited, false)
        #expect(sync.fileLoaded(edited, editing: false) == .none)
    }

    @Test func aSaveThatWorksEndsTheRetries() {
        var sync = loaded()
        sync.didSave(true, error: "disk full")
        sync.didSave(true, error: nil)
        #expect(sync.loaded == true)
        #expect(sync.status.problem == nil)
        #expect(sync.fileLoaded(file, editing: false) != .retrySave)
    }

    /// A file that could not be read when the window opened is not a change that was lost.
    @Test func anUnreadableFileHasItsOwnTitle() {
        let status = SaveStatus()
        status.setUnreadable()
        #expect(status.problem?.title == "Config file cannot be read")
        #expect(status.error == ConfigWriter.SyntaxError.message)
        // The first change made on the page then fails with the same message: now it is a change not saved.
        status.set(ConfigWriter.SyntaxError.message)
        #expect(status.problem?.title == "Changes not saved")
        status.fileIsValid()
        #expect(status.problem == nil)
    }
}

/// A reload while the user edits, and the errors of the save status.
@Suite struct FileSyncReloadTests {
    /// A reload that comes while the user edits is remembered, not lost; one that changes nothing is not.
    @Test func reloadWaitsForTheEdit() {
        var sync = FileSync<Void>(SyncedSlice(sections: "mouse"))
        sync.didLoad(["mouse": ["reverseScroll": true]])
        let same = sync.fileLoaded(["mouse": ["reverseScroll": true]], editing: true) == .reload
        #expect(!same && !sync.reloadDeferred)
        let whileEditing = sync.fileLoaded(["mouse": ["reverseScroll": false]], editing: true) == .reload
        #expect(!whileEditing && sync.reloadDeferred)
        let afterwards = sync.fileLoaded(["mouse": ["reverseScroll": false]], editing: false) == .reload
        #expect(afterwards)
    }

    /// A syntax error reported earlier goes once the file parses again; other errors stay.
    @Test func syntaxErrorClearsWhenTheFileIsValid() {
        let status = SaveStatus()
        status.set(ConfigWriter.SyntaxError.message)
        status.fileIsValid()
        #expect(status.error == nil)
        status.set("disk full")
        status.fileIsValid()
        #expect(status.error == "disk full")
    }

    /// A file that cannot be read has its own words, and they go once it is read again.
    @Test func anUnreadableFileIsNotASyntaxError() {
        let status = SaveStatus()
        status.setUnreadable(SaveStatus.unreadableMessage)
        #expect(status.error != ConfigWriter.SyntaxError.message)
        #expect(status.problem?.title == "Config file cannot be read")
        status.fileIsValid()
        #expect(status.problem == nil)
    }
}
