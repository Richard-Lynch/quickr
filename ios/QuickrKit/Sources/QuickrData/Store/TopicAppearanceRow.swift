import GRDB
import QuickrCore

/// A topic's appearance in the server layer (appearance.md §8): the `color`, `icon` and
/// `tags_json` columns of `topic` and `stage_topic` (``StoreSchema/t2m3``).
extension TopicAppearance {
    /// Writes `appearance` onto the row `ServerLayer.upsert` has just written, in its transaction.
    /// The `INSERT OR REPLACE` left the columns at their defaults, which are the empty appearance,
    /// so an unthemed topic writes nothing more: as for v2's `timer_json`, the seeds and the
    /// upgrade tests that build an older file with today's upserts keep working.
    static func write(_ db: Database, _ appearance: TopicAppearance, topicId id: String, table: String) throws {
        guard appearance != .empty else { return }
        try db.execute(
            sql: "UPDATE \(table) SET color = ?, icon = ?, tags_json = ? WHERE id = ?",
            arguments: [
                appearance.color?.rawValue, appearance.icon?.storeValue, try StoreJSON.encode(appearance.tags), id,
            ])
    }

    /// A `topic` row's appearance. A colour name this build doesn't know is a corrupt row: only
    /// what the DTOs decoded is ever written.
    init(serverRow row: Row) throws {
        let color: String? = row["color"]
        let icon: String? = row["icon"]
        let tags: String? = row["tags_json"]
        self.init(
            color: try color.map { name in
                guard let color = ColorName(rawValue: name) else {
                    throw StoreError.corruptRow("topic \(row["id"] as String? ?? "?") color")
                }
                return color
            },
            icon: icon.map(TopicIcon.emoji),
            tags: try tags.map { try StoreJSON.decode([String].self, $0) } ?? [])
    }
}

extension TopicIcon {
    /// The `icon` column: the emoji itself, the only kind in phase A (OQ-7).
    var storeValue: String {
        switch self {
        case .emoji(let value): value
        }
    }
}
