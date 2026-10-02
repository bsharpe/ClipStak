public enum SheetNavigation {
    public enum Direction { case left, right, up, down }

    /// Clips fill the grid in reading order, newest first.
    public static func move(_ direction: Direction, from index: Int, columns: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let last = count - 1, columns = max(columns, 1)
        let index = min(max(index, 0), last)
        switch direction {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, last)
        case .up: return index >= columns ? index - columns : index
        case .down:
            // A short last row has gaps; land on the oldest clip rather than stopping above them.
            guard index / columns < last / columns else { return index }
            return min(index + columns, last)
        }
    }
}
