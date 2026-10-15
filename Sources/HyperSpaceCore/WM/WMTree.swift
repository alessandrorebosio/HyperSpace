import CoreGraphics

/// CoreGraphics window id: stable for a window's whole life, unlike its AX element.
public typealias WindowID = UInt32

public enum Orientation: Sendable, Equatable {
    case horizontal, vertical

    public var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum ContainerLayout: Sendable, Equatable {
    /// Children side by side, sized by weight.
    case tiles
    /// Children stacked on top of each other, each offset by the accordion padding.
    case accordion
}

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down

    public var orientation: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    /// -1 towards the start of a container, +1 towards the end.
    public var offset: Int { self == .left || self == .up ? -1 : 1 }
}

/// A node of a workspace's tiling tree, i3/AeroSpace style: containers hold windows and
/// other containers; windows are leaves. The tree is kept normalized (`normalize()`):
/// no empty containers, no container with a single child (except the root), and nested
/// containers always alternate orientation, so every arrangement has one representation.
public final class WMNode {
    /// Set for windows (leaves), nil for containers.
    public internal(set) var window: WindowID?
    public var orientation: Orientation
    public var layout: ContainerLayout
    public private(set) var children: [WMNode] = []
    public private(set) weak var parent: WMNode?
    /// Share of the parent's length along the parent's orientation, relative to siblings.
    public var weight = 1.0
    /// The child that was focused last: where focus goes when entering this container.
    public private(set) weak var recent: WMNode?
    /// The container's length along its orientation at the last layout, to turn pixel
    /// resizes into weights.
    var lastLength = 0.0

    public init(window: WindowID) {
        self.window = window
        orientation = .horizontal
        layout = .tiles
    }

    public init(orientation: Orientation, layout: ContainerLayout = .tiles) {
        window = nil
        self.orientation = orientation
        self.layout = layout
    }

    public var isContainer: Bool { window == nil }
    public var index: Int? { parent?.children.firstIndex { $0 === self } }

    /// Swaps two nodes' places in the tree, weights included.
    public static func swap(_ a: WMNode, _ b: WMNode) {
        guard let pa = a.parent, let ia = a.index, let pb = b.parent, let ib = b.index, a !== b else { return }
        let (wa, wb) = (a.weight, b.weight)
        pa.children[ia] = b
        pb.children[ib] = a
        a.parent = pb
        b.parent = pa
        a.weight = wb
        b.weight = wa
    }

    /// Inserts `node` at `index` (end if nil), taking it from its current parent. The new
    /// child gets the average weight of its siblings, so it takes an even share.
    public func insert(_ node: WMNode, at index: Int? = nil) {
        node.removeFromParent()
        node.weight = children.isEmpty ? 1 : children.reduce(0) { $0 + $1.weight } / Double(children.count)
        children.insert(node, at: min(index ?? children.count, children.count))
        node.parent = self
    }

    public func removeFromParent() {
        guard let parent, let index else { return }
        parent.children.remove(at: index)
        if parent.recent === self { parent.recent = nil }
        self.parent = nil
    }

    /// Marks this node as the most recent all the way up to the root.
    public func markRecent() {
        var node = self
        while let parent = node.parent {
            parent.recent = node
            node = parent
        }
    }

    /// The window focus lands on when entering this node: the most recent path down.
    public var recentWindow: WMNode? {
        if !isContainer { return self }
        return (recent ?? children.first)?.recentWindow
    }

    public var windows: [WindowID] {
        if let window { return [window] }
        return children.flatMap(\.windows)
    }

    public func find(_ id: WindowID) -> WMNode? {
        if window == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }

    /// Removes empty containers, lifts single children into their parent and makes nested
    /// containers alternate orientation (AeroSpace's normalizations). Call on the root after
    /// every change.
    public func normalize() {
        clean()
        alternate()
    }

    private func clean() {
        for child in children where child.isContainer { child.clean() }
        for child in children where child.isContainer && child.children.isEmpty { child.removeFromParent() }
        // A container with one child is replaced by that child.
        for child in children where child.isContainer && child.children.count == 1 {
            let only = child.children[0], weight = child.weight, wasRecent = recent === child, index = child.index!
            child.removeFromParent()
            insert(only, at: index)
            only.weight = weight
            if wasRecent { recent = only }
        }
        // The root takes over a single container child: its orientation, layout and children.
        if parent == nil, children.count == 1, let only = children.first, only.isContainer {
            orientation = only.orientation
            layout = only.layout
            let grandchildren = only.children, onlyRecent = only.recent
            only.removeFromParent()
            for child in grandchildren {
                let weight = child.weight
                insert(child)
                child.weight = weight
            }
            recent = onlyRecent
        }
    }

    private func alternate() {
        for child in children where child.isContainer {
            if child.orientation == orientation { child.orientation = orientation.opposite }
            child.alternate()
        }
    }
}
