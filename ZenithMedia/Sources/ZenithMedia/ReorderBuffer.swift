/// Holds up to `depth` items and releases the lowest-PTS item once more arrive.
/// VideoToolbox emits frames in decode order; the display needs PTS order.
public struct ReorderBuffer<T> {
    private var items: [(Int64, T)] = []
    public let depth: Int

    public init(depth: Int) { self.depth = depth }

    public mutating func push(pts: Int64, _ item: T) -> [(Int64, T)] {
        let i = items.firstIndex { $0.0 > pts } ?? items.count
        items.insert((pts, item), at: i)
        guard items.count > depth else { return [] }
        return [items.removeFirst()]
    }

    /// Release everything with pts <= `limit`: once the frame with DTS d has
    /// decoded, every later frame has pts >= its dts > d, so nothing can come
    /// before a held frame whose pts <= d.
    public mutating func release(upTo limit: Int64) -> [(Int64, T)] {
        let n = items.firstIndex { $0.0 > limit } ?? items.count
        defer { items.removeFirst(n) }
        return Array(items.prefix(n))
    }

    public mutating func drain() -> [(Int64, T)] {
        defer { items.removeAll() }
        return items
    }
}
