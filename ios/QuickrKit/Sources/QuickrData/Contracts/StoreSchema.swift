import GRDB

/// The schema of one store file, `stores/<server_id>.g<store_gen>.sqlite` (sync-protocol.md §3.1,
/// outbox.md §2).
///
/// Conventions:
/// - Ids are lowercase UUID strings (`UUID.wireString`).
/// - Instants are `REAL` Unix seconds (microsecond precision), so `max()` and ordering work in SQL.
///   Lease-time deadlines are `(boot_id TEXT, *_ct INTEGER)` pairs, never wall clock.
/// - JSON columns hold the wire shapes: `questions_json` is `[QuestionDTO]`, `schedule_json` is
///   `ScheduleDTO`, `answers_json` is the request-shaped `{key: value}` map (the question says
///   whether a string is `str` or `enum`), `meta_json` is `{key: value}`.
/// - The server layer has **no foreign keys**: a page may carry an entry before its topic, and
///   the view's inner joins hide it until the topic arrives (§3.1).
/// - Server-derived fields (`entry_count`, `last_captured_at`, `due`) are not stored; the view
///   recomputes them (§3.3).
///
/// Migrations are append-only once a build has shipped (M7). Every process may run the migrator;
/// STORE runs `migrations` inside one `IMMEDIATE` transaction (PLAN §2), recording them in
/// `grdb_migrations` exactly as `migrator()` does, so the two agree.
public enum StoreSchema {
    /// The append-only migrations, in order: `(identifier, statements)`.
    public static let migrations: [(identifier: String, statements: [String])] = [("v1", v1)]

    public static func migrator() -> DatabaseMigrator { DatabaseMigrator(steps: migrations) }

    /// Every table the v1 migration creates, by layer.
    public static let serverLayerTables = ["topic", "topic_version", "entry", "tombstone"]
    public static let stageTables = ["stage_topic", "stage_topic_version", "stage_entry", "stage_tombstone"]
    public static let tables =
        serverLayerTables + ["sync_state"] + stageTables
        + ["stage_state", "outbox_item", "lease", "ui_draft", "stats_cache", "widget_state"]

    // The server layer and its staging copy share one definition, so a swap can copy rows 1:1.
    private static func serverLayer(prefix: String) -> [String] {
        [
            """
            CREATE TABLE \(prefix)topic (
              id                  TEXT PRIMARY KEY NOT NULL,
              slug                TEXT NOT NULL,
              name                TEXT NOT NULL,
              description         TEXT NOT NULL DEFAULT '',
              status              TEXT NOT NULL CHECK (status IN ('active', 'archived')),
              current_version     INTEGER NOT NULL,
              revision            INTEGER NOT NULL,
              question_count      INTEGER NOT NULL,
              created_at          REAL NOT NULL,
              updated_at          REAL NOT NULL,
              archived_at         REAL,
              schedule_json       TEXT,
              schedule_updated_at REAL,
              questions_json      TEXT NOT NULL
            )
            """,
            "CREATE INDEX ix_\(prefix)topic_slug ON \(prefix)topic(slug)",
            """
            CREATE TABLE \(prefix)topic_version (
              id             TEXT PRIMARY KEY NOT NULL,
              topic_id       TEXT NOT NULL,
              version        INTEGER NOT NULL,
              questions_json TEXT NOT NULL,
              change_note    TEXT NOT NULL DEFAULT '',
              created_at     REAL NOT NULL,
              UNIQUE (topic_id, version)
            )
            """,
            """
            CREATE TABLE \(prefix)entry (
              id           TEXT PRIMARY KEY NOT NULL,
              topic_id     TEXT NOT NULL,
              version      INTEGER NOT NULL,
              revision     INTEGER NOT NULL,
              source       TEXT NOT NULL,
              channel      TEXT NOT NULL,
              captured_at  REAL NOT NULL,
              created_at   REAL NOT NULL,
              updated_at   REAL NOT NULL,
              notes        TEXT NOT NULL DEFAULT '',
              meta_json    TEXT NOT NULL DEFAULT '{}',
              answers_json TEXT NOT NULL
            )
            """,
            "CREATE INDEX ix_\(prefix)entry_topic ON \(prefix)entry(topic_id, captured_at)",
            """
            CREATE TABLE \(prefix)tombstone (
              kind     TEXT NOT NULL CHECK (kind IN ('entry', 'topic', 'version')),
              id       TEXT NOT NULL,
              topic_id TEXT NOT NULL,
              seq      INTEGER,
              PRIMARY KEY (kind, id)
            )
            """,
            "CREATE INDEX ix_\(prefix)tombstone_topic ON \(prefix)tombstone(topic_id)",
        ]
    }

    static let v1: [String] =
        serverLayer(prefix: "")
        + [
            // One row (§3.1). Inserted by STORE when the store file is created (§2.1).
            """
            CREATE TABLE sync_state (
              id                 INTEGER PRIMARY KEY CHECK (id = 1),
              server_id          TEXT NOT NULL,
              base_url           TEXT NOT NULL,
              epoch              TEXT,
              cursor             INTEGER NOT NULL DEFAULT 0,
              head_seen          INTEGER NOT NULL DEFAULT 0,
              layer_gen          INTEGER NOT NULL DEFAULT 1,
              rebuilding         TEXT,
              epoch_suspect      INTEGER NOT NULL DEFAULT 0 CHECK (epoch_suspect IN (0, 1)),
              retired            INTEGER NOT NULL DEFAULT 0 CHECK (retired IN (0, 1)),
              identity_mismatch  INTEGER NOT NULL DEFAULT 0 CHECK (identity_mismatch IN (0, 1)),
              last_pull_at       REAL,
              skew_ms            REAL NOT NULL DEFAULT 0,
              skew_measured_at   REAL,
              bootstrap_complete INTEGER NOT NULL DEFAULT 0 CHECK (bootstrap_complete IN (0, 1))
            )
            """
        ]
        + serverLayer(prefix: "stage_")
        + [
            // The rebuild's own cursor (§7 step 2); the target epoch is sync_state.rebuilding.
            """
            CREATE TABLE stage_state (
              id     INTEGER PRIMARY KEY CHECK (id = 1),
              cursor INTEGER NOT NULL DEFAULT 0
            )
            """,
            "INSERT INTO stage_state (id, cursor) VALUES (1, 0)",
            // outbox.md §2, verbatim.
            """
            CREATE TABLE outbox_item (
              seq             INTEGER PRIMARY KEY AUTOINCREMENT,
              id              TEXT NOT NULL UNIQUE,
              kind            TEXT NOT NULL,
              entity_kind     TEXT NOT NULL,
              entity_id       TEXT NOT NULL,
              topic_id        TEXT NOT NULL,
              payload_json    TEXT NOT NULL,
              base_revision   INTEGER,
              state           TEXT NOT NULL CHECK (state IN ('held','pending','in_flight','uncertain','failed')),
              maybe_delivered INTEGER NOT NULL DEFAULT 0,
              attempts        INTEGER NOT NULL DEFAULT 0,
              due_boot_id     TEXT,
              due_ct          INTEGER,
              hold_boot_id    TEXT,
              hold_ct         INTEGER,
              claim_token     TEXT,
              claim_owner     TEXT,
              claim_layer_gen INTEGER,
              claim_epoch     TEXT,
              pre_claim_json  TEXT,
              failure_reason  TEXT,
              last_error_json TEXT,
              rebase_count    INTEGER NOT NULL DEFAULT 0,
              cancels_create  INTEGER NOT NULL DEFAULT 0,
              origin          TEXT NOT NULL,
              created_at      REAL NOT NULL,
              updated_at      REAL NOT NULL,
              row_version     INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX ix_outbox_entity ON outbox_item(entity_kind, entity_id, seq)",
            "CREATE INDEX ix_outbox_topic  ON outbox_item(topic_id, seq)",
            "CREATE INDEX ix_outbox_state  ON outbox_item(state)",
            // sync-protocol.md §5.3, verbatim, with its two rows.
            """
            CREATE TABLE lease (
              name       TEXT PRIMARY KEY,
              owner      TEXT,
              token      TEXT,
              boot_id    TEXT,
              expires_ct INTEGER
            )
            """,
            "INSERT INTO lease (name) VALUES ('sync'), ('flush')",
            // Local state (§3.1). Cleared per topic by a topic tombstone (§4.3 step 4).
            """
            CREATE TABLE ui_draft (
              key          TEXT PRIMARY KEY NOT NULL,
              topic_id     TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              updated_at   REAL NOT NULL
            )
            """,
            "CREATE INDEX ix_ui_draft_topic ON ui_draft(topic_id)",
            // Stats and series are cached only under the epoch they were fetched in (§11).
            """
            CREATE TABLE stats_cache (
              key          TEXT PRIMARY KEY NOT NULL,
              topic_id     TEXT NOT NULL,
              epoch        TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              fetched_at   REAL NOT NULL
            )
            """,
            "CREATE INDEX ix_stats_cache_topic ON stats_cache(topic_id)",
            """
            CREATE TABLE widget_state (
              key          TEXT PRIMARY KEY NOT NULL,
              topic_id     TEXT,
              payload_json TEXT NOT NULL,
              updated_at   REAL NOT NULL
            )
            """,
            "CREATE INDEX ix_widget_state_topic ON widget_state(topic_id)",
        ]
}

/// The schema of `registry.sqlite`, the app-global database next to the stores
/// (sync-protocol.md §8.1, §12; notifications.md §5.1, §9.2).
public enum RegistrySchema {
    /// The append-only migrations, in order: `(identifier, statements)`.
    public static let migrations: [(identifier: String, statements: [String])] = [("v1", v1)]

    public static func migrator() -> DatabaseMigrator { DatabaseMigrator(steps: migrations) }

    public static let tables = [
        "server", "active", "retired_file", "notification_category", "pending_unregister", "apns_state",
    ]

    static let v1: [String] = [
        // pending_* is the persisted reset intent (§12.1 step 2); all null when no reset runs.
        """
        CREATE TABLE server (
          server_id                 TEXT PRIMARY KEY NOT NULL,
          base_url                  TEXT NOT NULL,
          display_name              TEXT,
          store_gen                 INTEGER NOT NULL DEFAULT 1,
          created_at                REAL NOT NULL,
          last_sync_at              REAL,
          pending_gen               INTEGER,
          pending_confirmed_count   INTEGER,
          pending_confirmed_max_seq INTEGER
        )
        """,
        // The selected server; at most one row.
        """
        CREATE TABLE active (
          id        INTEGER PRIMARY KEY CHECK (id = 1),
          server_id TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE retired_file (
          path            TEXT PRIMARY KEY NOT NULL,
          retired_at_wall REAL NOT NULL,
          retired_boot_id TEXT NOT NULL,
          retired_ct      INTEGER NOT NULL
        )
        """,
        // notifications.md §5.1, verbatim. Append-only, never pruned in v1.
        """
        CREATE TABLE notification_category (
          id            TEXT PRIMARY KEY,
          server_id     TEXT NOT NULL,
          topic_id      TEXT NOT NULL,
          actions_json  TEXT NOT NULL,
          created_at    REAL NOT NULL
        )
        """,
        // APNs unregistrations still owed to a server, retried at launch for up to 30 days
        // (notifications.md §9.2). The deadline is lease time; `first_attempt_at` is wall clock.
        """
        CREATE TABLE pending_unregister (
          server_id        TEXT NOT NULL,
          token            TEXT NOT NULL,
          expect_epoch     TEXT,
          first_attempt_at REAL NOT NULL,
          attempts         INTEGER NOT NULL DEFAULT 0,
          due_boot_id      TEXT,
          due_ct           INTEGER,
          PRIMARY KEY (server_id, token)
        )
        """,
        // The device's APNs token and where it is registered (notifications.md §9); one row.
        """
        CREATE TABLE apns_state (
          id                   INTEGER PRIMARY KEY CHECK (id = 1),
          token                TEXT,
          environment          TEXT CHECK (environment IN ('sandbox', 'production')),
          registered_server_id TEXT,
          last_registered_at   REAL
        )
        """,
    ]
}

extension DatabaseMigrator {
    init(steps: [(identifier: String, statements: [String])]) {
        self.init()
        for (identifier, statements) in steps {
            registerMigration(identifier) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
    }
}
