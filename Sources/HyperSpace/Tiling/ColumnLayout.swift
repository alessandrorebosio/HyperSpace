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

        /// An accordion needs two windows: left with one, the column is a plain one.
        mutating func settle() {
            if windows.count < 2 { accordion = false }
        }
    }

    private(set) var columns: [Column] = []

    init() {}

    /// A saved arrangement; empty columns are dropped. `accordions` are indices into `columns`.
    init(columns: [[CGWindowID]], accordions: Set<Int> = []) {
        self.columns = columns.enumerated().filter { !$0.element.isEmpty }
            .map { Column(windows: $0.element, accordion: accordions.contains($0.offset) && $0.element.count > 1) }
    }

    /// Keeps the arrangement of the windows still in the workspace (on screen or not: see
    /// `restricted` for laying out those on screen), drops the others, and gives each
    /// new window its own column on the right; while `focused` is in an accordion, new
    /// windows join that accordion instead (right after it, in front).
    mutating func sync(with ids: [CGWindowID], focused: CGWindowID? = nil) {
        let present = Set(ids)
        columns = columns
            .map { column in
                var column = column
                column.windows = column.windows.filter(present.contains)
                column.settle()
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

    /// The window before (-1) or after (+1) `id` in its accordion, among `shown` (the windows
    /// on screen; nil: all of them): the ones out of sight are passed over.
    func accordionNeighbor(of id: CGWindowID, _ step: Int, among shown: Set<CGWindowID>? = nil) -> CGWindowID? {
        guard let (c, r) = locate(id), columns[c].accordion else { return nil }
        return Self.next(in: columns[c].windows, from: r, step, among: shown).map { columns[c].windows[$0] }
    }

    /// The index of the next window of `windows` after `row` going by `step` that is among `shown`.
    private static func next(in windows: [CGWindowID], from row: Int, _ step: Int, among shown: Set<CGWindowID>?) -> Int? {
        var index = row + step
        while windows.indices.contains(index) {
            if shown?.contains(windows[index]) ?? true { return index }
            index += step
        }
        return nil
    }

    /// The index of the next column after `column` going by `step` with a window among `shown`.
    private func nextColumn(from column: Int, _ step: Int, among shown: Set<CGWindowID>?) -> Int? {
        var index = column + step
        while columns.indices.contains(index) {
            if columns[index].windows.contains(where: { shown?.contains($0) ?? true }) { return index }
            index += step
        }
        return nil
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
    ///
    /// `shown` are the windows on screen (nil: all of them). The move is among them, as it
    /// looks: windows out of sight (minimized, hidden) keep their place and are passed over,
    /// so a window sharing its column only with such windows counts as alone in it.
    mutating func move(_ id: CGWindowID, _ direction: Direction, among shown: Set<CGWindowID>? = nil) {
        guard let (c, r) = locate(id) else { return }
        let step = direction == .left || direction == .up ? -1 : 1
        let sharesColumn = columns[c].windows.contains { $0 != id && (shown?.contains($0) ?? true) }
        switch direction {
        case .left, .right:
            if sharesColumn {
                // Out of a shared column (or an accordion) into a new column beside it.
                remove(id)
                columns.insert(Column(windows: [id]), at: direction == .left ? c : c + 1)
            } else {
                // Past the next column drawn; its own column goes along when it holds nothing else.
                guard let target = nextColumn(from: c, step, among: shown) else { return }
                let whole = columns[c].windows.count == 1
                let moved = whole ? columns[c] : Column(windows: [id])
                remove(id)
                let past = direction == .left ? target : target + 1
                columns.insert(moved, at: whole && target > c ? past - 1 : past)
            }
        case .up, .down:
            if let target = Self.next(in: columns[c].windows, from: r, step, among: shown) {
                columns[c].windows.swapAt(r, target)
            } else if !sharesColumn, let neighbour = nextColumn(from: c, -1, among: shown) ?? nextColumn(from: c, 1, among: shown),
                      let mate = columns[neighbour].windows.first {
                remove(id)
                // Located again: taking `id` out may have closed its column.
                guard let (into, _) = locate(mate) else { return }
                if direction == .down {
                    columns[into].windows.append(id)
                } else {
                    columns[into].windows.insert(id, at: 0)
                }
            }
        }
    }

    /// Exchanges two windows' places (drag and drop, `swap` in an accordion).
    mutating func swap(_ a: CGWindowID, _ b: CGWindowID) {
        guard let pa = locate(a), let pb = locate(b) else { return }
        columns[pa.column].windows[pa.row] = b
        columns[pb.column].windows[pb.row] = a
    }

    /// `new` takes the place of `old` (a window exchanged with one of another workspace).
    mutating func replace(_ old: CGWindowID, with new: CGWindowID) {
        guard locate(old) != nil else { return }
        remove(new)
        // Located again: taking `new` out may have shifted `old`.
        guard let (c, r) = locate(old) else { return }
        columns[c].windows[r] = new
        if columns[c].front == old { columns[c].front = new }
    }

    /// The arrangement with only `ids` (the windows on screen): the others' columns close up,
    /// and an accordion left with one window is a plain column, as long as they are away.
    func restricted(to ids: Set<CGWindowID>) -> ColumnLayout {
        var layout = self
        layout.columns = columns.compactMap { column in
            var column = column
            column.windows = column.windows.filter(ids.contains)
            guard !column.windows.isEmpty else { return nil }
            column.settle()
            if let front = column.front, !column.windows.contains(front) { column.front = nil }
            return column
        }
        return layout
    }

    /// Puts `id` back where it was in `saved` (a saved arrangement), among the windows of that
    /// arrangement already here: next to the nearest of its saved column-mates, else in a
    /// column of its own beside the columns of its saved neighbours, else on the right.
    mutating func insert(_ id: CGWindowID, saved: [[CGWindowID]]) {
        remove(id)
        guard let sc = saved.firstIndex(where: { $0.contains(id) }), let sr = saved[sc].firstIndex(of: id) else {
            return columns.append(Column(windows: [id]))
        }
        let mates = saved[sc]
        for above in mates[..<sr].reversed() {
            if let (c, r) = locate(above) { return columns[c].windows.insert(id, at: r + 1) }
        }
        for below in mates[(sr + 1)...] {
            if let (c, r) = locate(below) { return columns[c].windows.insert(id, at: r) }
        }
        for left in saved[..<sc].reversed() {
            if let c = left.compactMap({ locate($0)?.column }).max() { return columns.insert(Column(windows: [id]), at: c + 1) }
        }
        for right in saved[(sc + 1)...] {
            if let c = right.compactMap({ locate($0)?.column }).min() { return columns.insert(Column(windows: [id]), at: c) }
        }
        columns.append(Column(windows: [id]))
    }

    /// Takes a window out; a column left empty closes.
    private mutating func remove(_ id: CGWindowID) {
        guard let (c, r) = locate(id) else { return }
        columns[c].windows.remove(at: r)
        if columns[c].windows.isEmpty {
            columns.remove(at: c)
            return
        }
        columns[c].settle()
        if columns[c].front == id { columns[c].front = columns[c].windows[max(0, r - 1)] }
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
