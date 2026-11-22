import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

@Suite struct ColumnLayoutTests {
    @Test func stackAndUnstack() {
        var layout = ColumnLayout()
        layout.sync(with: [1, 2])
        layout.move(2, .down)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        layout.sync(with: [1, 2, 3])
        layout.move(3, .up)
        #expect(layout.columns.map(\.windows) == [[3, 1, 2]])
        layout.move(3, .down)
        #expect(layout.columns.map(\.windows) == [[1, 3, 2]])
        layout.move(2, .right)
        #expect(layout.columns.map(\.windows) == [[1, 3], [2]])
        layout.move(2, .left)
        #expect(layout.columns.map(\.windows) == [[2], [1, 3]])
        layout.sync(with: [1, 2])
        #expect(layout.columns.map(\.windows) == [[2], [1]])
    }

    @Test func frames() {
        var layout = ColumnLayout()
        layout.sync(with: [1, 2])
        let side = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 610), gap: 10, peek: 30) { _ in 1 }
        #expect(side[1] == CGRect(x: 0, y: 0, width: 500, height: 610))
        #expect(side[2] == CGRect(x: 510, y: 0, width: 500, height: 610))
        layout.move(2, .down)
        let stacked = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 610), gap: 10, peek: 30) { _ in 1 }
        #expect(stacked[2] == CGRect(x: 0, y: 310, width: 1010, height: 300))
    }

    /// A saved arrangement drops its empty columns.
    @Test func emptySavedColumnsAreDropped() {
        let layout = ColumnLayout(columns: [[10, 11], [], [12]])
        #expect(layout.columns.map(\.windows) == [[10, 11], [12]])
        #expect(ColumnLayout().frames(in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 0, peek: 0) { _ in 1 }.isEmpty)
    }

    @Test func columnWeightsSizeTheColumns() {
        var layout = ColumnLayout(columns: [[1], [2]])
        layout.setColumnWeight(0, 2)
        // Out of range: nothing changes.
        layout.setColumnWeight(5, 3)
        #expect(layout.columns.map(\.weight) == [2, 1])
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 600), gap: 10, peek: 30) { _ in 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 666, height: 600))
        #expect(frames[2] == CGRect(x: 676, y: 0, width: 334, height: 600))
    }

    /// Windows sharing a column are sized by their own weights.
    @Test func windowWeightsSizeTheRows() {
        let layout = ColumnLayout(columns: [[1, 2]])
        let weights: [CGWindowID: CGFloat] = [1: 1, 2: 3]
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 610), gap: 10, peek: 30) { weights[$0] ?? 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 150))
        #expect(frames[2] == CGRect(x: 0, y: 160, width: 1000, height: 450))
    }

    @Test func locateAndAccordionMembership() {
        let layout = ColumnLayout(columns: [[1, 2], [3], [4, 5]], accordions: [0, 1])
        #expect(layout.locate(2).map { [$0.column, $0.row] } == [0, 1])
        #expect(layout.locate(5).map { [$0.column, $0.row] } == [2, 1])
        #expect(layout.locate(9) == nil)
        #expect(layout.isInAccordion(1) && layout.isInAccordion(2))
        // A column of one window is no accordion, whatever was saved.
        #expect(!layout.isInAccordion(3))
        #expect(!layout.isInAccordion(4))
        #expect(!layout.isInAccordion(9))
    }
}

@Suite struct ColumnAccordionTests {
    /// Two windows side by side → one accordion → moving one out puts them side by side again.
    @Test func toggleAndMoveOut() {
        var layout = ColumnLayout(columns: [[1], [2]])
        let on = layout.toggleAccordion(around: 2)
        #expect(on)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        #expect(layout.columns[0].accordion && layout.columns[0].front == 2)
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 10, peek: 30) { _ in 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 970, height: 600))
        #expect(frames[2] == CGRect(x: 30, y: 0, width: 970, height: 600))
        layout.move(2, .right)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        #expect(!layout.columns[0].accordion)
    }

    @Test func toggleOffAndNewWindows() {
        var layout = ColumnLayout(columns: [[1], [2, 3]])
        layout.toggleAccordion(around: 1)
        // A new window opened while the accordion has the focus joins it.
        layout.sync(with: [1, 2, 3, 4], focused: 1)
        #expect(layout.columns.map(\.windows) == [[1, 4, 2, 3]])
        #expect(layout.accordionNeighbor(of: 4, 1) == 2)
        let still = layout.toggleAccordion(around: 4)
        #expect(!still)
        #expect(layout.columns.map(\.windows) == [[1], [4], [2], [3]])
    }
}

/// Column operations beyond stacking and the accordion toggle.
@Suite struct ColumnOperationTests {
    @Test func aLoneWindowMovingUpOrDownJoinsItsNeighbour() {
        var layout = ColumnLayout(columns: [[1, 2], [3]])
        layout.move(3, .down)
        #expect(layout.columns.map(\.windows) == [[1, 2, 3]])
        var top = ColumnLayout(columns: [[1], [2, 3]])
        top.move(1, .up)
        #expect(top.columns.map(\.windows) == [[1, 2, 3]])
    }

    @Test func swapExchangesPlaces() {
        var layout = ColumnLayout(columns: [[1, 2], [3]])
        layout.swap(1, 3)
        #expect(layout.columns.map(\.windows) == [[3, 2], [1]])
    }

    @Test func accordionFrontAndNeighbours() {
        var layout = ColumnLayout(columns: [[1, 2, 3]], accordions: [0])
        layout.setFront(2)
        #expect(layout.columns[0].front == 2)
        #expect(layout.accordionNeighbor(of: 2, -1) == 1)
        #expect(layout.accordionNeighbor(of: 2, 1) == 3)
        #expect(layout.accordionNeighbor(of: 3, 1) == nil)
    }
}

/// Columns keep the windows out of sight (minimized, hidden, another Space).
@Suite struct ColumnMembershipTests {
    @Test func windowsOutOfSightKeepTheirColumn() {
        var layout = ColumnLayout(columns: [[1, 2], [3], [4]])
        // 2 and 3 are minimized: still members, so the sync keeps them.
        layout.sync(with: [1, 2, 3, 4])
        #expect(layout.columns.map(\.windows) == [[1, 2], [3], [4]])
        // Only what is on screen is laid out, closing up the gaps.
        let shown = layout.restricted(to: [1, 4])
        #expect(shown.columns.map(\.windows) == [[1], [4]])
        let frames = shown.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 600), gap: 10, peek: 30) { _ in 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(frames[4] == CGRect(x: 510, y: 0, width: 500, height: 600))
        #expect(frames[2] == nil && frames[3] == nil)
        // Back on screen: where they were.
        #expect(layout.restricted(to: [1, 2, 3, 4]).columns.map(\.windows) == [[1, 2], [3], [4]])
    }

    @Test func accordionOutOfSightIsAPlainColumnMeanwhile() {
        var layout = ColumnLayout(columns: [[1, 2, 3]], accordions: [0])
        layout.setFront(2)
        let shown = layout.restricted(to: [1])
        #expect(!shown.columns[0].accordion && shown.columns[0].front == nil)
        #expect(layout.columns[0].accordion && layout.columns[0].front == 2)
    }

    @Test func replaceTakesTheSlot() {
        var layout = ColumnLayout(columns: [[1, 2], [3]], accordions: [0])
        layout.setFront(1)
        layout.replace(1, with: 9)
        #expect(layout.columns.map(\.windows) == [[9, 2], [3]])
        #expect(layout.columns[0].front == 9)
        // A window already in the layout moves into the slot.
        layout.replace(9, with: 3)
        #expect(layout.columns.map(\.windows) == [[3, 2]])
        // Not there: nothing changes.
        layout.replace(42, with: 2)
        #expect(layout.columns.map(\.windows) == [[3, 2]])
    }

    @Test func restoredWindowGoesBackToItsPlace() {
        let saved: [[CGWindowID]] = [[1, 2], [3], [4, 5]]
        var layout = ColumnLayout(columns: [[1], [4]])
        // Next to a saved column-mate: below the one above it, above the one below it.
        layout.insert(2, saved: saved)
        #expect(layout.columns.map(\.windows) == [[1, 2], [4]])
        layout.insert(5, saved: saved)
        #expect(layout.columns.map(\.windows) == [[1, 2], [4, 5]])
        // No column-mate here: a column of its own beside its saved neighbours'.
        layout.insert(3, saved: saved)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3], [4, 5]])
        // Already placed (as a new column on the right): moved, not duplicated.
        var late = ColumnLayout(columns: [[4], [1]])
        late.insert(1, saved: saved)
        #expect(late.columns.map(\.windows) == [[1], [4]])
        // Unknown to the saved arrangement: on the right.
        late.insert(8, saved: saved)
        #expect(late.columns.map(\.windows) == [[1], [4], [8]])
    }
}

/// Column moves go by the windows on screen: the ones out of sight are passed over.
@Suite struct ColumnMovesAmongShownTests {
    @Test func aloneOnScreenInItsColumnSwapsWithTheNextColumnDrawn() {
        // 2 is minimized: 1 is alone on screen in its column, 3 is out of sight too.
        var layout = ColumnLayout(columns: [[1, 2], [3], [4]])
        layout.move(1, .right, among: [1, 4])
        #expect(layout.columns.map(\.windows) == [[2], [3], [4], [1]])
        layout.move(1, .left, among: [1, 4])
        #expect(layout.columns.map(\.windows) == [[2], [3], [1], [4]])
        // Nothing drawn further that way: it stays.
        layout.move(4, .right, among: [1, 4])
        #expect(layout.columns.map(\.windows) == [[2], [3], [1], [4]])
    }

    @Test func aWholeColumnKeepsItsWeightPastColumnsOutOfSight() {
        var layout = ColumnLayout(columns: [[1], [2], [3]])
        layout.setColumnWeight(0, 2)
        layout.move(1, .right, among: [1, 3])
        #expect(layout.columns.map(\.windows) == [[2], [3], [1]])
        #expect(layout.columns.map(\.weight) == [1, 1, 2])
    }

    @Test func upAndDownPassOverRowsOutOfSight() {
        var layout = ColumnLayout(columns: [[1, 2, 3], [4]])
        layout.move(1, .down, among: [1, 3, 4])
        #expect(layout.columns.map(\.windows) == [[3, 2, 1], [4]])
        // Alone on screen in its column: it joins the next column drawn.
        var alone = ColumnLayout(columns: [[1, 2], [3], [4]])
        alone.move(4, .down, among: [1, 4])
        #expect(alone.columns.map(\.windows) == [[1, 2, 4], [3]])
    }

    @Test func withEveryWindowOnScreenNothingChanges() {
        var layout = ColumnLayout(columns: [[1], [2], [3]])
        layout.move(1, .right)
        #expect(layout.columns.map(\.windows) == [[2], [1], [3]])
        layout.move(1, .down)
        #expect(layout.columns.map(\.windows) == [[2, 1], [3]])
        layout.move(1, .left)
        #expect(layout.columns.map(\.windows) == [[1], [2], [3]])
    }

    @Test func accordionNeighbourSkipsWindowsOutOfSight() {
        let layout = ColumnLayout(columns: [[1, 2, 3]], accordions: [0])
        #expect(layout.accordionNeighbor(of: 1, 1, among: [1, 3]) == 3)
        #expect(layout.accordionNeighbor(of: 3, -1, among: [1, 3]) == 1)
        #expect(layout.accordionNeighbor(of: 3, 1, among: [1, 3]) == nil)
        #expect(layout.accordionNeighbor(of: 1, 1) == 2)
    }
}
