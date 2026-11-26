import GRDB

/// Milestone T2-M1's store migrations (t2-plan.md "iOS store migrations"): registered in
/// ``StoreSchema/migrations`` after the `v` series, with ``t2m1ServerLayerTables`` added to
/// ``StoreSchema/serverLayerTables``, both at the merge. Identifiers are `t2m1_*`, and no
/// migration here reads another milestone's columns, so M3's `t2m3_*` may run before or after them.
extension StoreSchema {
    public static let t2m1Migrations: [(identifier: String, statements: [String])] = [
        ("t2m1_run_closed", t2m1RunClosed)
    ]

    /// The server-layer tables T2-M1 adds, each with a `stage_` copy (a swap copies them 1:1).
    public static let t2m1ServerLayerTables = ["run_closed"]

    /// A closed marker that never prunes below the topic tombstone's guard: an alias, or a run
    /// deleted with its topic (timers2.md §5.2, "∞"). The largest SQLite integer.
    public static let closedForever = Int.max

    /// The closed-run markers (timers2.md §5.2): a `run` deletion means closed, not gone, so a
    /// later `reopen` may upsert the run again. Instead of a permanent tombstone, a closed run
    /// keeps `run_closed(id, revision)`, and an upsert applies only above `revision`. `closed_at`
    /// is the device's wall clock at the marker's latest write (`RunInstant` text, UTC), for the
    /// 30-day prune.
    ///
    /// Every `run` tombstone (live and staged) becomes a marker and is deleted: revision ∞ when its
    /// topic is tombstoned too (it was deleted with its topic), else 0 (a real reopen carries
    /// revision ≥ 1; the server never upserts a discarded run or an alias as a run, so 0 on one of
    /// those is harmless). Tombstones don't record whether an id was an alias, so a live topic's
    /// aliases get 0 like runs.
    ///
    /// `layer_gen` moves, so no outcome of a request claimed or started before the migration is
    /// applied after it (the §5.5 fence; timers2.md §5.2 lifetime invariant 1).
    static let t2m1RunClosed: [String] =
        ["", "stage_"].flatMap { prefix in
            [
                """
                CREATE TABLE \(prefix)run_closed (
                  id        TEXT PRIMARY KEY NOT NULL,
                  revision  INTEGER NOT NULL,
                  closed_at TEXT NOT NULL
                )
                """,
                """
                INSERT INTO \(prefix)run_closed (id, revision, closed_at)
                SELECT t.id,
                       CASE WHEN EXISTS (
                         SELECT 1 FROM \(prefix)tombstone p WHERE p.kind = 'topic' AND p.id = t.topic_id
                       ) THEN \(closedForever) ELSE 0 END,
                       strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                FROM \(prefix)tombstone t WHERE t.kind = 'run'
                """,
                "DELETE FROM \(prefix)tombstone WHERE kind = 'run'",
            ]
        }
        + ["UPDATE sync_state SET layer_gen = layer_gen + 1 WHERE id = 1"]
}
