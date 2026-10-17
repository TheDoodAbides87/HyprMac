import CoreGraphics

/// A node in Hyprland's "dwindle" binary layout tree. Leaves hold a window;
/// containers split their rect between `first` and `second` at `ratio`.
final class Node {
    weak var parent: Node?
    var win: CGWindowID?
    var first: Node?
    var second: Node?
    var vertical = true          // true: children side by side; false: stacked
    var ratio: CGFloat = 0.5
    var rect: CGRect = .zero

    init(win: CGWindowID? = nil) { self.win = win }

    var isLeaf: Bool { win != nil }

    func leaves() -> [Node] {
        if isLeaf { return [self] }
        return (first?.leaves() ?? []) + (second?.leaves() ?? [])
    }

    func find(_ id: CGWindowID) -> Node? {
        if win == id { return self }
        return first?.find(id) ?? second?.find(id)
    }
}

final class Workspace {
    enum FullscreenMode { case full, maximize }

    let n: Int
    var root: Node?
    var focused: CGWindowID?
    var fullscreen: CGWindowID?
    var fullscreenMode: FullscreenMode = .full
    var monitor: CGDirectDisplayID?

    init(_ n: Int) { self.n = n }
}

enum Dwindle {
    /// Splits the leaf holding `near` (or the last leaf) and puts the new window
    /// in the right/bottom half — Hyprland's `force_split = 2`. The split axis
    /// follows the longer side of the tile being split, which yields the spiral.
    static func insert(_ ws: Workspace, _ id: CGWindowID, near: CGWindowID?) {
        let leaf = Node(win: id)
        guard let root = ws.root else { ws.root = leaf; return }
        guard let target = near.flatMap({ root.find($0) }) ?? root.leaves().last else { return }
        let container = Node()
        container.rect = target.rect
        container.vertical = target.rect == .zero || target.rect.width >= target.rect.height
        replace(target, with: container, in: ws)
        container.first = target
        container.second = leaf
        target.parent = container
        leaf.parent = container
    }

    static func remove(_ ws: Workspace, _ id: CGWindowID) {
        guard let node = ws.root?.find(id) else { return }
        guard let parent = node.parent else { ws.root = nil; return }
        guard let sibling = parent.first === node ? parent.second : parent.first else { return }
        replace(parent, with: sibling, in: ws)
    }

    static func swap(_ ws: Workspace, _ a: CGWindowID, _ b: CGWindowID) {
        guard let na = ws.root?.find(a), let nb = ws.root?.find(b) else { return }
        na.win = b
        nb.win = a
    }

    static func layout(_ node: Node, _ rect: CGRect) {
        node.rect = rect
        guard !node.isLeaf, let a = node.first, let b = node.second else { return }
        if node.vertical {
            let w = (rect.width * node.ratio).rounded()
            layout(a, CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
            layout(b, CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
        } else {
            let h = (rect.height * node.ratio).rounded()
            layout(a, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h))
            layout(b, CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
        }
    }

    /// Nearest ancestor splitting along the given axis, and whether `node` is in its first half.
    static func ancestor(of node: Node, vertical: Bool) -> (Node, Bool)? {
        var child = node
        var p = node.parent
        while let cur = p {
            if cur.vertical == vertical { return (cur, cur.first === child) }
            child = cur
            p = cur.parent
        }
        return nil
    }

    /// The split that forms one edge of `node`'s tile: its right/bottom edge when
    /// `farEdge` (the node is in that split's first half), its left/top edge otherwise.
    static func edgeSplit(of node: Node, vertical: Bool, farEdge: Bool) -> Node? {
        var child = node
        var p = node.parent
        while let cur = p {
            if cur.vertical == vertical && (cur.first === child) == farEdge { return cur }
            child = cur
            p = cur.parent
        }
        return nil
    }

    /// Moves one edge of `node`'s tile by `delta` points, so it follows the pointer.
    /// Falls back to the opposite edge when the tile touches the screen edge on that side.
    static func moveEdge(of node: Node, vertical: Bool, farEdge: Bool, by delta: CGFloat) {
        guard delta != 0,
              let split = edgeSplit(of: node, vertical: vertical, farEdge: farEdge)
                ?? edgeSplit(of: node, vertical: vertical, farEdge: !farEdge) else { return }
        let length = vertical ? split.rect.width : split.rect.height
        guard length > 0 else { return }
        split.ratio = min(0.9, max(0.1, split.ratio + delta / length))
    }

    private static func replace(_ old: Node, with new: Node, in ws: Workspace) {
        if let p = old.parent {
            if p.first === old { p.first = new } else { p.second = new }
            new.parent = p
        } else {
            ws.root = new
            new.parent = nil
        }
    }
}
