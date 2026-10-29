import CoreGraphics

/// i3-like columns: the workspace is split into columns side by side, and each column
/// is a vertical stack of windows. Pure data, so it is easy to reason about and test.
struct ColumnLayout {
    struct Column: Equatable {
        var windows: [CGWindowID]
        var weight: CGFloat = 1
    }

    private(set) var columns: [Column] = []

    init() {}

    /// A saved arrangement; empty columns are dropped.
    init(columns: [[CGWindowID]]) {
        self.columns = columns.filter { !$0.isEmpty }.map { Column(windows: $0) }
    }

    /// Keeps the arrangement of windows still tiled, drops the others, and gives each
    /// new window its own column on the right.
    mutating func sync(with ids: [CGWindowID]) {
        let present = Set(ids)
        columns = columns
            .map { Column(windows: $0.windows.filter(present.contains), weight: $0.weight) }
            .filter { !$0.windows.isEmpty }
        let placed = Set(columns.flatMap(\.windows))
        for id in ids where !placed.contains(id) { columns.append(Column(windows: [id])) }
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
                columns[c].windows.remove(at: r)
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

    func frames(in area: CGRect, gap: CGFloat, weight: (CGWindowID) -> CGFloat) -> [CGWindowID: CGRect] {
        guard !columns.isEmpty else { return [:] }
        var result: [CGWindowID: CGRect] = [:]
        let columnRects = Layout.split(area, weights: columns.map(\.weight), horizontally: true, gap: gap)
        for (column, rect) in zip(columns, columnRects) {
            let rows = Layout.split(rect, weights: column.windows.map(weight), horizontally: false, gap: gap)
            for (id, frame) in zip(column.windows, rows) { result[id] = frame }
        }
        return result
    }
}
