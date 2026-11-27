import GRDB

/// Milestone T2-M3a's store migrations (t2-plan.md "iOS store migrations"): registered in
/// ``StoreSchema/migrations`` after the `v` series and **after** M1's `t2m1_*`. Identifiers are
/// `t2m3_*`. No migration here reads another milestone's columns, but `t2m3_topic_appearance`
/// clears M1's staging tables (``StoreSchema/t2m1ServerLayerTables``), so it must run after `t2m1_*`
/// has created them (`StoreMigrationOrderTests`).
extension StoreSchema {
    public static let t2m3Migrations: [(identifier: String, statements: [String])] = [
        ("t2m3_topic_appearance", t2m3TopicAppearance)
    ]

    /// Topic appearance (appearance.md §8): `color` (a palette name, null when none), `icon` (the
    /// emoji, null when none) and `tags_json` (`[String]`, the stored spellings), in both layers at
    /// the end, so a swap still copies rows 1:1.
    ///
    /// A topic synced before it has no appearance here, though the server may have given it one
    /// (themed on another device), and nothing re-sends a topic whose own fields don't change. So,
    /// as v2 does, a store that has synced re-pulls its whole server layer through the rebuild
    /// (sync-protocol.md §7): staging starts over, and `rebuilding` targets the epoch it already
    /// has (or the one it was already staging). A store with no epoch yet has nothing to re-pull.
    /// Staging starts over in every server-layer table, M1's `stage_run_closed` too (the `t2m1_*`
    /// migrations before this one created it, and `t2m1_run_closed` fills it from staged run
    /// tombstones without restarting staging). The clears are plain `DELETE`s, so running them on
    /// an already-empty staging layer is a no-op.
    static let t2m3TopicAppearance: [String] =
        ["", "stage_"].flatMap { prefix in
            [
                "ALTER TABLE \(prefix)topic ADD COLUMN color TEXT",
                "ALTER TABLE \(prefix)topic ADD COLUMN icon TEXT",
                "ALTER TABLE \(prefix)topic ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'",
            ]
        }
        + (["topic", "topic_version", "entry", "tombstone", "run", "run_alias"] + t2m1ServerLayerTables).map {
            "DELETE FROM stage_\($0)"
        }
        + [
            "UPDATE stage_state SET cursor = 0 WHERE id = 1",
            "UPDATE sync_state SET rebuilding = COALESCE(rebuilding, epoch) WHERE id = 1 AND epoch IS NOT NULL",
        ]
}
