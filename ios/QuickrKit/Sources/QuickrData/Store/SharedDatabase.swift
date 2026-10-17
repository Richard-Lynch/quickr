import Foundation
import GRDB
import SQLite3

/// Opening a database file that several processes share (app, widget, NSE), with GRDB's
/// multi-process recipe (research/02-architecture.md §2, GRDB "Sharing a Database"):
///
/// - a WAL `DatabasePool` with **persistent WAL**, so the `-wal` and `-shm` files are never deleted
///   under another process;
/// - `busyMode = .timeout`, so a writer waits for another process instead of failing;
/// - `observesSuspensionNotifications`, so the app can post `Database.suspendNotification` before
///   it is suspended and never holds a lock while suspended (0xDEAD10CC);
/// - creation guarded by `NSFileCoordinator`;
/// - file protection `completeUntilFirstUserAuthentication` on the directory and the files, so
///   notification actions can write while the device is locked;
/// - the append-only migrations run by **any** process inside **one** `IMMEDIATE` transaction
///   (PLAN §2, §6a rule 14);
/// - a Darwin notification after every committed write transaction (sync-protocol.md §4.1 step 7).
///
/// **App obligation (not wired here):** `observesSuspensionNotifications` only takes effect when
/// the process posts the notifications. The app must post `Database.suspendNotification` when it
/// is about to be suspended (`scenePhase` → `.background`, after any background work, and from
/// every `beginBackgroundTask` expiration handler and `BGTask` expiration handler), and
/// `Database.resumeNotification` when it becomes active again and at the start of every
/// background callback that touches a store (`BGAppRefreshTask`, push, notification action).
/// Extensions don't need to: they never stay suspended with a lock held.
///
/// Nothing here is process-global: every call opens what it is given, so a test subprocess can
/// open the same file with the same code.
public enum SharedDatabase {
    public typealias Migrations = [(identifier: String, statements: [String])]

    /// Opens (creating if needed) the shared pool at `url` and migrates it.
    ///
    /// - Parameter commitSignal: posted through `notifier` after every transaction that changed
    ///   rows (`.dbChanged` for stores, `.registryChanged` for the registry). Pass a nil notifier
    ///   to post nothing.
    public static func openPool(
        at url: URL, migrations: Migrations, notifier: (any ChangeNotifier)?, commitSignal: ChangeSignalName
    ) throws -> DatabasePool {
        try createProtectedDirectory(url.deletingLastPathComponent())
        var configuration = StoreDatabase.configuration(label: url.lastPathComponent)
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            if !db.configuration.readonly { try enablePersistentWAL(db) }
            if let notifier {
                db.add(
                    transactionObserver: CommitSignal(notifier: notifier, name: commitSignal), extent: .databaseLifetime
                )
            }
        }
        let pool = try coordinated(writingItemAt: url) { url in
            try DatabasePool(path: url.path, configuration: configuration)
        }
        try migrate(pool, migrations)
        protect(url)
        return pool
    }

    /// Runs every unapplied migration inside one `IMMEDIATE` transaction, recording each in
    /// `grdb_migrations` like `DatabaseMigrator`, so `migrator().hasCompletedMigrations` agrees.
    /// Two processes that race here are serialised by SQLite's write lock, and the loser finds
    /// nothing left to apply.
    public static func migrate(_ writer: any DatabaseWriter, _ migrations: Migrations) throws {
        let known = Set(migrations.map(\.identifier))
        let applied = try writer.read { db in try appliedIdentifiers(db) }
        if known.isSubset(of: applied) {
            guard applied.isSubset(of: known) else { throw StoreError.schemaTooNew(Array(applied.subtracting(known))) }
            return
        }
        try writer.barrierWriteWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                let applied = try appliedIdentifiers(db)
                guard applied.isSubset(of: known) else {
                    throw StoreError.schemaTooNew(Array(applied.subtracting(known)))
                }
                for (identifier, statements) in migrations where !applied.contains(identifier) {
                    for statement in statements { try db.execute(sql: statement) }
                    try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
                }
                return .commit
            }
        }
    }

    private static func appliedIdentifiers(_ db: Database) throws -> Set<String> {
        guard try db.tableExists("grdb_migrations") else { return [] }
        return Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
    }

    private static func enablePersistentWAL(_ db: Database) throws {
        var flag: CInt = 1
        let code = withUnsafeMutablePointer(to: &flag) { flagPointer in
            sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagPointer)
        }
        guard code == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
    }

    /// Runs `body` under a coordinated write of `url`, so two processes never create the same file
    /// at once.
    static func coordinated<T>(writingItemAt url: URL, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<T, any Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) { url in
            result = Result { try body(url) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw StoreError.coordinationFailed(url.path) }
        return try result.get()
    }

    static func createProtectedDirectory(_ directory: URL) throws {
        #if os(macOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #endif
    }

    /// Sets `completeUntilFirstUserAuthentication` on the database and its WAL files. A no-op on
    /// macOS, which has no data protection classes for these files.
    static func protect(_ url: URL) {
        #if !os(macOS)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path)
        {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        }
        #endif
    }
}

/// Posts a Darwin notification after every committed transaction that changed rows. Installed on
/// every connection of a shared pool; only the writer connection ever commits changes. GRDB calls
/// it on that connection's queue, so the flag is never touched concurrently.
private final class CommitSignal: TransactionObserver, @unchecked Sendable {
    private let notifier: any ChangeNotifier
    private let name: ChangeSignalName
    private var changed = false

    init(notifier: any ChangeNotifier, name: ChangeSignalName) {
        self.notifier = notifier
        self.name = name
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }

    func databaseDidChange(with event: DatabaseEvent) { changed = true }

    func databaseDidCommit(_ db: Database) {
        guard changed else { return }
        changed = false
        notifier.post(name)
    }

    func databaseDidRollback(_ db: Database) { changed = false }
}
