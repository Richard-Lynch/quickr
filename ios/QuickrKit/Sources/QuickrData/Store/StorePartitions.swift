import Foundation
import GRDB

/// One store file per `server_id` and store generation, found through the registry
/// (sync-protocol.md §8), with the storage-level parts of local reset and its crash recovery
/// (§12). SYNC orchestrates the reset (warning, leases, bootstrap); this type owns the files.
public struct StorePartitions: Sendable {
    /// Which process is opening: only the app resumes an interrupted reset (§12.2 row 1).
    public enum Role: Sendable, Hashable {
        case app
        case `extension`
    }

    public enum OpenResult: Sendable {
        case opened(LocalStore)
        /// A reset intent is persisted and the old file isn't retired yet (crashed between steps 2
        /// and 4). The app resumes at step 3 on this file with the persisted confirmed count.
        case resetPending(LocalStore, RegisteredServer)

        /// The store to use now (for `resetPending`, the old file, as extensions do).
        public var store: LocalStore {
            switch self {
            case .opened(let store), .resetPending(let store, _): store
            }
        }
    }

    /// Retired files are deleted once retired this long in lease time, or after a reboot (§12.1 step 9).
    public static let retiredFileGrace: Duration = .seconds(600)

    public let location: StoreLocation
    public let registry: Registry
    public let leaseClock: any LeaseClock
    public let wallClock: any WallClock
    public let notifier: (any ChangeNotifier)?

    public init(
        location: StoreLocation, registry: Registry, leaseClock: any LeaseClock, wallClock: any WallClock,
        notifier: (any ChangeNotifier)?
    ) {
        self.location = location
        self.registry = registry
        self.leaseClock = leaseClock
        self.wallClock = wallClock
        self.notifier = notifier
    }

    /// Opens the registry at `location` and returns the partitions over it.
    public static func open(
        at location: StoreLocation, leaseClock: any LeaseClock = SystemLeaseClock(),
        wallClock: any WallClock = SystemWallClock(), notifier: (any ChangeNotifier)? = DarwinNotifier()
    ) throws -> StorePartitions {
        StorePartitions(
            location: location, registry: try Registry.open(at: location, notifier: notifier), leaseClock: leaseClock,
            wallClock: wallClock, notifier: notifier)
    }

    // MARK: - Opening

    /// §2.1 step 3, "no store exists": registers the server at `store_gen = 1` (if new) and opens
    /// its store, creating the file with its `sync_state`.
    public func createStore(serverId: String, baseURL: String, displayName: String? = nil) async throws -> LocalStore {
        _ = try await registry.register(
            serverId: serverId, baseURL: baseURL, displayName: displayName, now: wallClock.now())
        return try await openStore(serverId: serverId, role: .app).store
    }

    /// The active server's store, or nil when none is selected.
    public func openActiveStore(role: Role) async throws -> OpenResult? {
        guard let serverId = try await registry.repository.activeServerId() else { return nil }
        return try await openStore(serverId: serverId, role: role)
    }

    /// Opens a server's store at its current generation, running the §12.2 recovery first. Safe
    /// to call from any process, at any time; every recovery step is idempotent and fenced on the
    /// registry state it inspected, so a step based on a stale read writes nothing and recovery
    /// restarts from a fresh read. Call it again whenever `registry-changed` arrives, the app
    /// becomes active, an extension starts, or a transaction fails with `StoreError.retired` (§8.1).
    public func openStore(serverId: String, role: Role) async throws -> OpenResult {
        for _ in 0..<Self.recoveryAttempts {
            let server = try await requireServer(serverId)
            if let pendingGen = server.pendingGen {
                // An intent without a token can't be fenced; treat it as unidentified and stop.
                guard let token = server.pendingToken else { throw StoreError.registryChanged(serverId) }
                let old = try openExisting(server)
                if let old, try await !old.isRetired() {
                    // Crashed between steps 2 and 4: the old file is still live.
                    if try await registryUnchanged(server) {
                        return role == .app ? .resetPending(old, server) : .opened(old)
                    }
                    continue
                }
                // Crashed between steps 4 and 6 (or the old file is gone): finish step 6 for
                // exactly the generations inspected, then re-read whatever the outcome.
                try await registry.completeReset(
                    serverId: serverId, fromGen: server.storeGen, toGen: pendingGen, token: token,
                    retiredAtWall: wallClock.now(),
                    retiredAt: leaseClock.now())
                continue
            }
            if let current = try openExisting(server), try await current.isRetired() {
                // Unreachable in theory: the registry points at a retired file. Move past it.
                try await registry.repairRetiredPointer(
                    serverId: serverId, retiredGen: server.storeGen, retiredAtWall: wallClock.now(),
                    retiredAt: leaseClock.now())
                continue
            }
            let store = try await open(server)
            if try await registryUnchanged(server) { return .opened(store) }
        }
        throw StoreError.registryChanged(serverId)
    }

    /// How many times `openStore` re-reads the registry before giving up with `registryChanged`.
    static let recoveryAttempts = 8

    // MARK: - Reset primitives (§12.1)

    /// Step 2 for `store`'s file: fails with `registryChanged` if that file is no longer the
    /// server's current generation or a reset is already in progress. Returns the server with
    /// its intent; pass it to `completeReset` or `abortReset`.
    public func persistResetIntent(store: LocalStore, confirmedCount: Int, confirmedMaxSeq: Int64) async throws
        -> RegisteredServer
    {
        try await registry.persistResetIntent(
            serverId: store.serverId, storeGen: store.storeGen, confirmedCount: confirmedCount,
            confirmedMaxSeq: confirmedMaxSeq)
    }

    /// Steps 6–8 after `LocalStore.retire` returned `.retired` and both leases were released:
    /// advance exactly `intent`'s generations (the registry commit posts `registry-changed`),
    /// then create and open the new, empty file. The caller bootstraps it. Throws
    /// `registryChanged` if the intent was superseded.
    public func completeReset(_ intent: RegisteredServer) async throws -> LocalStore {
        guard let pendingGen = intent.pendingGen, let token = intent.pendingToken else {
            throw StoreError.registryChanged(intent.id)
        }
        let completion = try await registry.completeReset(
            serverId: intent.id, fromGen: intent.storeGen, toGen: pendingGen, token: token,
            retiredAtWall: wallClock.now(),
            retiredAt: leaseClock.now())
        guard completion != .superseded else { throw StoreError.registryChanged(intent.id) }
        return try await openStore(serverId: intent.id, role: .app).store
    }

    /// Abort `intent` (lease timeout in step 3, or writes arrived in step 4). Clears only that
    /// attempt (fenced on its token); returns whether it did.
    @discardableResult
    public func abortReset(_ intent: RegisteredServer) async throws -> Bool {
        guard let token = intent.pendingToken else { return false }
        return try await registry.clearResetIntent(serverId: intent.id, token: token)
    }

    /// Step 9, app only: deletes retired files once retired for `retiredFileGrace` of lease time
    /// or since a reboot, never a file the registry still points at. Returns the deleted paths.
    @discardableResult
    public func deleteRetiredFiles() async throws -> [String] {
        let now = leaseClock.now()
        let live = Set(try await registry.repository.servers().map(\.storeFileName))
        var deleted: [String] = []
        for file in try await registry.retiredFiles() where !live.contains(file.path) {
            guard now.hasPassed(deadline: file.retiredAt.adding(Self.retiredFileGrace)) else { continue }
            let url = location.url(file.path)
            for path in [url.path, url.path + "-wal", url.path + "-shm"]
            where FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            try await registry.forgetRetiredFile(path: file.path)
            deleted.append(file.path)
        }
        return deleted
    }

    // MARK: - Files

    private func registryUnchanged(_ server: RegisteredServer) async throws -> Bool {
        let now = try await requireServer(server.id)
        return now.storeGen == server.storeGen && now.pendingGen == server.pendingGen
            && now.pendingToken == server.pendingToken
    }

    private func requireServer(_ serverId: String) async throws -> RegisteredServer {
        guard let server = try await registry.repository.server(id: serverId) else {
            throw StoreError.unknownServer(serverId)
        }
        return server
    }

    /// Opens the server's current file if it exists, without creating it.
    private func openExisting(_ server: RegisteredServer) throws -> LocalStore? {
        guard FileManager.default.fileExists(atPath: location.storeURL(for: server).path) else { return nil }
        return try openPool(server)
    }

    /// Opens (creating and migrating) the server's current file, with its `sync_state`.
    private func open(_ server: RegisteredServer) async throws -> LocalStore {
        let store = try openPool(server)
        let exists = try await store.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sync_state WHERE id = 1)") ?? false
        }
        if !exists {
            try await store.writer.write { db in
                try LocalStore.createSyncState(db, serverId: server.id, baseURL: server.baseURL)
            }
        }
        return store
    }

    private func openPool(_ server: RegisteredServer) throws -> LocalStore {
        let url = location.storeURL(for: server)
        let pool = try SharedDatabase.openPool(
            at: url, migrations: StoreSchema.migrations, notifier: notifier, commitSignal: .dbChanged)
        return LocalStore(
            serverId: server.id, storeGen: server.storeGen, url: url, writer: pool, leaseClock: leaseClock,
            wallClock: wallClock)
    }
}
