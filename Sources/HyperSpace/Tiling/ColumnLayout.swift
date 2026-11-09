import CoreGraphics

/// i3-like columns: the workspace is split into columns side by side, and each column
/// is a vertical stack of windows. Pure data, so it is easy to reason about and test.
struct ColumnLayout {
    struct Column: Equatable {
        var windows: [CGWindowID]
        var weight: CGFloat = 1
        /// The windows overlap as an accordion (see `Layout.accordion`) instead of stacking.
        var accordion = false
        /// The accordion's window in front: the one focused last.
        var front: CGWindowID?
    }

    private(set) var columns: [Column] = []

    init() {}

    /// A saved arrangement; empty columns are dropped. `accordions` are indices into `columns`.
    init(columns: [[CGWindowID]], accordions: Set<Int> = []) {
        self.columns = columns.enumerated().filter { !$0.element.isEmpty }
            .map { Column(windows: $0.element, accordion: accordions.contains($0.offset) && $0.element.count > 1) }
    }

    /// Keeps the arrangement of windows still tiled, drops the others, and gives each
    /// new window its own column on the right; while `focused` is in an accordion, new
    /// windows join that accordion instead (right after it, in front).
    mutating func sync(with ids: [CGWindowID], focused: CGWindowID? = nil) {
        let present = Set(ids)
        columns = columns
            .map { column in
                var column = column
                column.windows = column.windows.filter(present.contains)
                if column.windows.count < 2 { column.accordion = false }
                return column
            }
            .filter { !$0.windows.isEmpty }
        let placed = Set(columns.flatMap(\.windows))
        let into = focused.flatMap(locate).flatMap { columns[$0.column].accordion ? $0 : nil }
        var insertAt = into.map { $0.row + 1 }
        for id in ids where !placed.contains(id) {
            if let into, let at = insertAt {
                columns[into.column].windows.insert(id, at: at)
                columns[into.column].front = id
                insertAt = at + 1
            } else {
                columns.append(Column(windows: [id]))
            }
        }
    }

    func isInAccordion(_ id: CGWindowID) -> Bool {
        locate(id).map { columns[$0.column].accordion } ?? false
    }

    /// Accordion on: every window of the workspace goes into one accordion, in order, with
    /// `id` in front. Off (when `id` is in an accordion): each of its windows gets its own column again.
    /// Returns whether `id` is now in an accordion.
    @discardableResult
    mutating func toggleAccordion(around id: CGWindowID) -> Bool {
        guard let (c, _) = locate(id) else { return false }
        if columns[c].accordion {
            let unstacked = columns[c].windows.map { Column(windows: [$0]) }
            columns.replaceSubrange(c...c, with: unstacked)
            return false
        }
        let all = columns.flatMap(\.windows)
        guard all.count > 1 else { return false }
        columns = [Column(windows: all, accordion: true, front: id)]
        return true
    }

    /// Brings `id` to the front of its accordion.
    mutating func setFront(_ id: CGWindowID) {
        guard let (c, _) = locate(id), columns[c].accordion else { return }
        columns[c].front = id
    }

    /// The window before (-1) or after (+1) `id` in its accordion.
    func accordionNeighbor(of id: CGWindowID, _ step: Int) -> CGWindowID? {
        guard let (c, r) = locate(id), columns[c].accordion, columns[c].windows.indices.contains(r + step) else { return nil }
        return columns[c].windows[r + step]
    }

    func locate(_ id: CGWindowID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.windows.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    /// Moves a window:
    /// - left/right: out of a shared column into a new one on that side, or, alone,
    ///   swaps its column with the neighbour.
    /// - up/down: swaps with the window above/below in its column, or, alone, joins
    ///   the neighbouring column (left first) at the top/bottom.
    mutating func move(_ id: CGWindowID, _ direction: Direction) {
        guard let (c, r) = locate(id) else { return }
        switch direction {
        case .left, .right:
            if columns[c].windows.count > 1 {
                // Out of a shared column (or an accordion) into a new column beside it.
                columns[c].windows.remove(at: r)
                if columns[c].windows.count < 2 { columns[c].accordion = false }
                if columns[c].front == id { columns[c].front = columns[c].windows[max(0, r - 1)] }
                columns.insert(Column(windows: [id]), at: direction == .left ? c : c + 1)
            } else {
                let target = c + (direction == .left ? -1 : 1)
                guard columns.indices.contains(target) else { return }
                columns.swapAt(c, target)
            }
        case .up, .down:
            let target = r + (direction == .up ? -1 : 1)
            if columns[c].windows.indices.contains(target) {
                columns[c].windows.swapAt(r, target)
            } else if columns[c].windows.count == 1, columns.count > 1 {
                let neighbour = c > 0 ? c - 1 : c + 1
                columns.remove(at: c)
                let into = neighbour > c ? neighbour - 1 : neighbour
                if direction == .down {
                    columns[into].windows.append(id)
                } else {
                    columns[into].windows.insert(id, at: 0)
                }
            }
        }
    }

    /// Exchanges two windows' places (drag and drop).
    mutating func swap(_ a: CGWindowID, _ b: CGWindowID) {
        guard let pa = locate(a), let pb = locate(b) else { return }
        columns[pa.column].windows[pa.row] = b
        columns[pb.column].windows[pb.row] = a
    }

    mutating func setColumnWeight(_ column: Int, _ weight: CGFloat) {
        guard columns.indices.contains(column) else { return }
        columns[column].weight = weight
    }

    func frames(in area: CGRect, gap: CGFloat, peek: CGFloat, weight: (CGWindowID) -> CGFloat) -> [CGWindowID: CGRect] {
        guard !columns.isEmpty else { return [:] }
        var result: [CGWindowID: CGRect] = [:]
        let columnRects = Layout.split(area, weights: columns.map(\.weight), horizontally: true, gap: gap)
        for (column, rect) in zip(columns, columnRects) {
            if column.accordion {
                let front = column.front.flatMap { column.windows.firstIndex(of: $0) } ?? 0
                let frames = Layout.accordion(count: column.windows.count, focused: front, in: rect, peek: peek)
                for (id, frame) in zip(column.windows, frames) { result[id] = frame }
                continue
            }
            let rows = Layout.split(rect, weights: column.windows.map(weight), horizontally: false, gap: gap)
            for (id, frame) in zip(column.windows, rows) { result[id] = frame }
        }
        return result
    }
}
