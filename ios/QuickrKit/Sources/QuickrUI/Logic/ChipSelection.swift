/// Selection rules for ``ChipGrid``, mirroring the PWA's chips in `AnswerField.tsx`.
/// Values are option values (strings); `order` is the options' display order.
public enum ChipSelection {
    /// Single select (radio semantics). Tapping the selected chip clears it only when the
    /// question is optional; a required question always keeps an answer.
    public static func toggle(_ current: String?, tapped: String, required: Bool) -> String? {
        if current == tapped { return required ? tapped : nil }
        return tapped
    }

    /// Multi select (checkbox semantics). A selected chip deselects. An unselected chip is added
    /// unless the selection is full, and the result keeps the options' order.
    public static func toggle(_ current: [String], tapped: String, max: Int?, order: [String]) -> [String] {
        if current.contains(tapped) { return current.filter { $0 != tapped } }
        if isFull(count: current.count, max: max) { return current }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return (current + [tapped]).sorted { (rank[$0] ?? 0) < (rank[$1] ?? 0) }
    }

    public static func isFull(count: Int, max: Int?) -> Bool {
        guard let max else { return false }
        return count >= max
    }

    /// At the limit the unselected chips dim (they stay visible and announced).
    public static func isDimmed(_ value: String, in current: [String], max: Int?) -> Bool {
        isFull(count: current.count, max: max) && !current.contains(value)
    }

    /// Record-screen layout on a phone is two columns; with 3 or fewer options and an odd count,
    /// the last chip spans both.
    public static func isWide(index: Int, count: Int) -> Bool {
        count <= 3 && count % 2 == 1 && index == count - 1
    }

    /// Tile quick-log layout: one option fills the row, six use three columns, the rest two.
    public static func quickColumns(count: Int) -> Int {
        if count == 1 { return 1 }
        return count > 3 && count % 3 == 0 ? 3 : 2
    }
}
