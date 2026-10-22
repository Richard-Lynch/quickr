import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization

/// A file-backed store (outbox.md §13: "all cases run against a file-backed store"), fake lease
/// and wall clocks, and a `FakeServer` reached through the real `APIClient`. One topic `T` exists
/// on the server and in the local server layer. A second `process()` opens its own pool on the
/// same file, sharing the clocks, to simulate another process in one test process.
final class OutboxHarness: Sendable {
    let directory: TempDirectory
    let url: URL
    let store: LocalStore
    let clock = FakeLeaseClock()
    let wall = FakeClock(Make.t0)
    let server = FakeServer()
    let topic: Topic
    private let signalLog = Mutex<[OutboxSignal]>([])

    init(topicRevision: Int = 1, topicStatus: TopicStatus = .active) throws {
        directory = try TempDirectory()
        url = directory.url.appending(path: "store.sqlite")
        topic = Make.topic(revision: topicRevision, status: topicStatus)
        store = try Self.open(url, clock: clock, wall: wall, bootstrap: true)
        server.put(topic)
        try write { db in _ = try ServerLayer.upsert(db, topic: self.topic) }
    }

    deinit { directory.cleanup() }

    private static func open(_ url: URL, clock: FakeLeaseClock, wall: FakeClock, bootstrap: Bool) throws -> LocalStore {
        let pool = try StoreDatabase.openPool(at: url)
        if bootstrap {
            try pool.write { db in
                try LocalStore.createSyncState(db, serverId: "server-1", baseURL: FakeServer.base.absoluteString)
                try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            }
        }
        return LocalStore(serverId: "server-1", storeGen: 1, url: url, writer: pool, leaseClock: clock, wallClock: wall)
    }

    /// An outbox for one process. `origin` is the client's surface; `random` the backoff jitter.
    func outbox(
        owner: String = "app:1", store: LocalStore? = nil, random: Double = 0.5,
        shutdownGrace: Duration = .milliseconds(500)
    ) -> Outbox {
        let client = APIClient(baseURL: FakeServer.base, transport: server, identity: StaticServerIdentity(nil))
        return Outbox(
            store: store ?? self.store, sender: client, owner: owner,
            onSignal: { [self] signal in self.signalLog.withLock { $0.append(signal) } }, random: { random },
            shutdownGrace: shutdownGrace)
    }

    /// The rows a superseded or abandoned sender must not touch (its own lease release aside).
    func snapshot() throws -> [String] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM outbox_item ORDER BY seq").map(\.description)
                + Row.fetchAll(db, sql: "SELECT * FROM entry ORDER BY id").map(\.description)
                + Row.fetchAll(db, sql: "SELECT * FROM tombstone ORDER BY id").map(\.description)
                + Row.fetchAll(db, sql: "SELECT * FROM sync_state").map(\.description)
        }
    }

    /// Another process: its own pool on the same file, the same clocks.
    func process(_ owner: String) throws -> Outbox {
        outbox(owner: owner, store: try Self.open(url, clock: clock, wall: wall, bootstrap: false))
    }

    var signals: [OutboxSignal] { signalLog.withLock { $0 } }

    // MARK: Database

    func write<T>(_ body: (Database) throws -> T) throws -> T { try store.writer.write(body) }

    func read<T>(_ body: (Database) throws -> T) throws -> T { try store.writer.read(body) }

    var items: [OutboxItem] { get throws { try read { db in try OutboxStorage.items(db) } } }

    func item(_ id: String) throws -> OutboxItem? { try read { db in try OutboxStorage.item(db, id: id) } }

    func item(_ id: UUID) throws -> OutboxItem? { try item(id.wireString) }

    func view(_ id: UUID) throws -> ViewEntry? { try read { db in try StoreView.entry(db, id: id.wireString) } }

    func viewEntries() throws -> [ViewEntry] {
        try read { db in try StoreView.entries(db, topicId: self.topic.id.wireString) }
    }

    func syncState() async throws -> SyncState? { try await store.syncState.syncState() }

    func flag(_ column: String) throws -> Bool {
        try read { db in try Bool.fetchOne(db, sql: "SELECT \(column) FROM sync_state WHERE id = 1") ?? false }
    }

    func setSyncState(_ sql: String) throws { try write { db in try db.execute(sql: "UPDATE sync_state SET \(sql)") } }

    func lease() throws -> LeaseRecord { try read { db in try LeaseTable.record(db, .flush) } }

    func isTombstoned(_ id: UUID) throws -> Bool {
        try read { db in try ServerLayer.isTombstoned(db, kind: .entry, id: id.wireString) }
    }

    /// An entry that exists on the server and in the local server layer.
    @discardableResult
    func seedEntry(revision: Int = 1, notes: String = "") throws -> Entry {
        let entry = Make.entry(topicId: topic.id, revision: revision, notes: notes)
        server.put(entry)
        try write { db in _ = try ServerLayer.upsert(db, entry: entry) }
        return entry
    }

    /// What sync's page transaction does for a deletion (sync-protocol.md §4.3).
    func applyTombstone(_ kind: Deletion.EntityKind, id: UUID, topicId: UUID) throws {
        let now = wall.now()
        try write { db in
            try ServerLayer.applyDeletion(db, kind: kind, id: id, topicId: topicId, seq: nil)
            try OutboxSyncEffects.resolveDependents(db, kind: kind, id: id.wireString, wall: now)
        }
    }

    /// What sync's page transaction does when a page carries this row (§4.2, §4.4).
    func applyPage(_ entry: Entry) throws {
        try write { db in
            _ = try ServerLayer.upsert(db, entry: entry)
            try OutboxSyncEffects.pullAck(db, entryId: entry.id.wireString)
        }
    }

    // MARK: Payloads

    func create(minutes: Double = 0, answers: [String: AnswerValue] = ["mood": .int(4)]) -> EntryCreateDTO {
        EntryCreateDTO(
            id: nil, answers: answers, source: nil, capturedAt: Make.t0.addingTimeInterval(minutes * 60), version: 1)
    }

    var ref: TopicRef { TopicRef(id: topic.id, slug: topic.slug, name: topic.name) }

    /// Enqueues a create and returns its id.
    @discardableResult
    func log(_ outbox: Outbox, minutes: Double = 0, answers: [String: AnswerValue] = ["mood": .int(4)])
        async throws -> UUID
    {
        let id = UUID()
        try await outbox.createEntry(id: id, topic: ref, body: create(minutes: minutes, answers: answers), origin: .app)
        return id
    }

    func patch(notes: String? = nil, mood: Int? = nil) -> EntryUpdateDTO {
        EntryUpdateDTO(answers: mood.map { ["mood": .int($0)] }, notes: notes)
    }
}

extension OutboxItem {
    /// `last_error_json`, decoded.
    var errorInfo: OutboxErrorInfo? {
        get throws {
            try lastErrorJSON.map { try WireCoding.decoder().decode(OutboxErrorInfo.self, from: Data($0.utf8)) }
        }
    }
}

extension HTTPRequest {
    var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    var expectedRevision: Int? {
        if let value = json?["expected_revision"] as? Int { return value }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expected_revision" }?.value.flatMap(Int.init)
    }
}

/// Runs a flush in the background and lets the test wait for it.
func background(_ body: @escaping @Sendable () async throws -> OutboxFlushReport) -> Task<OutboxFlushReport, any Error>
{
    Task { try await body() }
}

extension Outbox {
    /// A forced flush with a generous budget, as the app does on activation.
    func flushNow(force: Bool = true, budget: Duration = .seconds(120)) async throws -> OutboxFlushReport {
        try await flush(force: force, budget: budget)
    }
}

/// `QUICKR_TIMING_SLACK` (a multiplier, default 1, never below 1) scales the slack of a timing
/// bound, never the budget it is added to: a run on a knowingly loaded machine can set it to 3.
/// CI never sets it.
func timingSlack(_ slack: Duration) -> Duration {
    let factor = ProcessInfo.processInfo.environment["QUICKR_TIMING_SLACK"].flatMap(Double.init) ?? 1
    return slack * max(1, factor)
}
