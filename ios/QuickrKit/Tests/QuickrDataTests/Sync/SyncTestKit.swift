import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// A quickR server's change feed, simulated from the shapes of the recorded `listChanges`
/// fixtures (shared/fixtures/api/listChanges.*.json): a change_log of `(seq, kind, id)` rows over
/// the current entities and `deleted_ids`, paged the way `services/changes.py` pages it
/// (sync-protocol.md F1–F3, F8): a page covers `after < seq ≤ next` (`limit` counts log rows),
/// each entity appears once in its latest state, a vanished entity is emitted as a deletion only
/// if its id is in `deleted_ids`. A closed run is emitted as a deletion only on the page with its
/// own delete row (timers.md §7.1).
final class FakeFeedServer: @unchecked Sendable {
    struct Snapshot {
        var epoch: String
        var log: [(seq: Int, kind: String, id: String)]
        var topics: [String: [String: Any]]
        var versions: [String: [String: Any]]
        var entries: [String: [String: Any]]
        /// Open and finishing runs (`RunOut`).
        var runs: [String: [String: Any]] = [:]
        /// The seq of each closed run's delete row.
        var runsClosedAt: [String: Int] = [:]
        var deleted: [String: (kind: String, id: String, topicId: String)]
    }

    static let defaultServerId = "00000000-0000-4000-8000-000000000009"
    static let fixtureEpoch = "00000000-0000-4000-8000-000000000008"
    static let water = "00000000-0000-4000-8000-000000000003"
    static let everything = "00000000-0000-4000-8000-000000000001"
    static let oldHabit = "00000000-0000-4000-8000-000000000002"

    private let lock = NSLock()
    private var state: Snapshot
    private var serverIdValue = FakeFeedServer.defaultServerId
    private var templates: (topic: [String: Any], version: [String: Any], entry: [String: Any])
    /// Answers a request before the feed does (a 500, a proxy page, a different header).
    private var interceptor: (@Sendable (Int) -> HTTPResponse?)?

    init(seedFixture: Bool = true) throws {
        let fixture = try Fixtures.api("listChanges.bootstrap")
        let raw = try #require(fixture.body)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let items = try #require(body["items"] as? [[String: Any]])
        let topic = try #require(items.first { ($0["kind"] as? String) == "topic" }?["topic"] as? [String: Any])
        let version = try #require(items.first { ($0["kind"] as? String) == "version" })
        let entry = try #require(
            items.first {
                (($0["entry"] as? [String: Any])?["topic_id"] as? String) == Self.water
            }?["entry"] as? [String: Any])
        templates = (topic, version, entry)
        state = Snapshot(
            epoch: Self.fixtureEpoch, log: [], topics: [:], versions: [:], entries: [:], deleted: [:])
        guard seedFixture else { return }
        for item in items {
            let seq = try #require(item["seq"] as? Int)
            switch item["kind"] as? String {
            case "topic":
                let topic = try #require(item["topic"] as? [String: Any])
                let id = try #require(topic["id"] as? String)
                state.topics[id] = topic
                state.log.append((seq, "topic", id))
            case "version":
                let id = try #require(item["id"] as? String)
                state.versions[id] = item
                state.log.append((seq, "version", id))
            default:
                let entry = try #require(item["entry"] as? [String: Any])
                let id = try #require(entry["id"] as? String)
                state.entries[id] = entry
                state.log.append((seq, "entry", id))
            }
        }
        state.log.sort { $0.seq < $1.seq }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var serverId: String {
        get { locked { serverIdValue } }
        set { locked { serverIdValue = newValue } }
    }

    var epoch: String { locked { state.epoch } }

    var head: Int { locked { state.log.last?.seq ?? 0 } }

    func intercept(_ body: (@Sendable (Int) -> HTTPResponse?)?) { locked { interceptor = body } }

    // MARK: Mutations (each logs one change_log row, as the service does)

    private func nextSeq() -> Int { (state.log.last?.seq ?? 0) + 1 }

    @discardableResult
    func addTopic(id: UUID = UUID(), name: String) -> String {
        locked {
            var topic = templates.topic
            let id = id.wireString
            topic["id"] = id
            topic["name"] = name
            topic["slug"] = name.lowercased().replacingOccurrences(of: " ", with: "-")
            topic["revision"] = 1
            state.topics[id] = topic
            state.log.append((nextSeq(), "topic", id))
            return id
        }
    }

    @discardableResult
    func addVersion(topicId: String, number: Int, id: UUID = UUID()) -> String {
        locked {
            var item = templates.version
            var version = item["version"] as? [String: Any] ?? [:]
            version["version"] = number
            item["version"] = version
            item["id"] = id.wireString
            item["topic_id"] = topicId
            state.versions[id.wireString] = item
            state.log.append((nextSeq(), "version", id.wireString))
            return id.wireString
        }
    }

    @discardableResult
    func addEntry(id: UUID = UUID(), topicId: String = FakeFeedServer.water, glasses: Int = 1, minutes: Int = 0)
        -> String
    {
        locked {
            var entry = templates.entry
            let id = id.wireString
            entry["id"] = id
            entry["topic_id"] = topicId
            entry["revision"] = 1
            entry["answers"] = [["key": "glasses", "type": "int", "value": glasses]]
            entry["captured_at"] = WireDate.format(Make.t0.addingTimeInterval(Double(minutes) * 60))
            state.entries[id] = entry
            state.log.append((nextSeq(), "entry", id))
            return id
        }
    }

    /// A PATCH: a new revision and a new log row.
    func updateEntry(_ id: String, glasses: Int) {
        locked {
            guard var entry = state.entries[id] else { return }
            entry["revision"] = (entry["revision"] as? Int ?? 1) + 1
            entry["answers"] = [["key": "glasses", "type": "int", "value": glasses]]
            state.entries[id] = entry
            state.log.append((nextSeq(), "entry", id))
        }
    }

    func deleteEntry(_ id: String) {
        locked {
            guard let entry = state.entries.removeValue(forKey: id) else { return }
            state.deleted["entry:\(id)"] = ("entry", id, entry["topic_id"] as? String ?? "")
            state.log.append((nextSeq(), "entry", id))
        }
    }

    /// A run created or changed while open or finishing: its new state and a new log row.
    func putRun(_ run: [String: Any]) {
        locked {
            let id = run["id"] as? String ?? ""
            state.runs[id] = run
            state.log.append((nextSeq(), "run", id))
        }
    }

    /// Stop or discard (timers.md §2.4): a stop's entry is logged first, then the run's delete.
    func closeRun(_ id: String, entry: [String: Any]? = nil) {
        locked {
            guard let run = state.runs.removeValue(forKey: id) else { return }
            if let entry, let entryId = entry["id"] as? String {
                state.entries[entryId] = entry
                state.log.append((nextSeq(), "entry", entryId))
            }
            let seq = nextSeq()
            state.deleted["run:\(id)"] = ("run", id, run["topic_id"] as? String ?? "")
            state.runsClosedAt[id] = seq
            state.log.append((seq, "run", id))
        }
    }

    /// Children go into `deleted_ids` before the cascade (runs and their aliases as kind `run`);
    /// only the topic's own row is logged (F3).
    func deleteTopic(_ id: String) {
        locked {
            for (runId, run) in state.runs where run["topic_id"] as? String == id {
                state.runs[runId] = nil
                for alias in [runId] + (run["aliases"] as? [String] ?? []) {
                    state.deleted["run:\(alias)"] = ("run", alias, id)
                }
            }
            for (entryId, entry) in state.entries where entry["topic_id"] as? String == id {
                state.entries[entryId] = nil
                state.deleted["entry:\(entryId)"] = ("entry", entryId, id)
            }
            for (versionId, version) in state.versions where version["topic_id"] as? String == id {
                state.versions[versionId] = nil
                state.deleted["version:\(versionId)"] = ("version", versionId, id)
            }
            state.topics[id] = nil
            state.deleted["topic:\(id)"] = ("topic", id, id)
            state.log.append((nextSeq(), "topic", id))
        }
    }

    func rotateEpoch(to epoch: String = UUID().uuidString.lowercased()) {
        locked { state.epoch = epoch }
    }

    func snapshot() -> Snapshot { locked { state } }

    /// A database restore: the state goes back; the epoch is whatever the snapshot had (someone
    /// may forget `make rotate-epoch`).
    func restore(_ snapshot: Snapshot) { locked { state = snapshot } }

    /// Entity ids and revisions as the server holds them (for "final state equals the server's").
    func liveEntries() -> [String: Int] {
        locked { state.entries.mapValues { $0["revision"] as? Int ?? 0 } }
    }

    func liveTopicIds() -> Set<String> { locked { Set(state.topics.keys) } }

    // MARK: Logs

    /// `POST /api/v1/topics/{id}/entries`: records the entry under the id the client sent (so a
    /// pull carries it) and answers 201 with it, as the server would (the `glasses` answer only).
    func respondToCreate(_ request: HTTPRequest) throws -> HTTPResponse {
        let body = try #require(
            try request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let parts = request.url.pathComponents  // ["/", "api", "v1", "topics", id, "entries"]
        let topicId = try #require(parts.count == 6 ? parts[4] : nil)
        let id = try #require((body["id"] as? String).flatMap(UUID.init(uuidString:)))
        let glasses = (body["answers"] as? [String: Any])?["glasses"] as? Int ?? 0
        let existing = locked { state.entries[id.wireString] }
        if existing == nil { addEntry(id: id, topicId: topicId, glasses: glasses) }
        return try locked {
            HTTPResponse(
                status: existing == nil ? 201 : 200,
                headers: [QuickrHeader.serverId: serverIdValue, QuickrHeader.epoch: state.epoch],
                body: try JSONSerialization.data(withJSONObject: state.entries[id.wireString]!, options: [.sortedKeys]))
        }
    }

    // MARK: The feed

    func respond(_ request: HTTPRequest) throws -> HTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let after = Int(query.first { $0.name == "after" }?.value ?? "0") ?? 0
        let limit = min(Int(query.first { $0.name == "limit" }?.value ?? "500") ?? 500, 500)
        if let response = locked({ interceptor })?(after) { return response }
        return try locked {
            let head = state.log.last?.seq ?? 0
            let rows = Array(state.log.filter { $0.seq > after }.prefix(limit))
            let next = rows.last?.seq ?? after
            var latest: [String: Int] = [:]
            for row in rows { latest["\(row.kind):\(row.id)"] = row.seq }
            var items: [String: [[String: Any]]] = ["topic": [], "version": [], "entry": [], "run": []]
            var deleted: [String: [[String: Any]]] = ["topic": [], "version": [], "entry": [], "run": []]
            for (key, seq) in latest.sorted(by: { $0.value < $1.value }) {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                let (kind, id) = (parts[0], parts[1])
                switch kind {
                case "topic" where state.topics[id] != nil:
                    items["topic"]!.append(["kind": "topic", "seq": seq, "topic": state.topics[id]!])
                case "version" where state.versions[id] != nil:
                    var item = state.versions[id]!
                    item["seq"] = seq
                    items["version"]!.append(item)
                case "entry" where state.entries[id] != nil:
                    items["entry"]!.append(["kind": "entry", "seq": seq, "entry": state.entries[id]!])
                case "run" where state.runs[id] != nil:
                    items["run"]!.append(["kind": "run", "seq": seq, "run": state.runs[id]!])
                default:
                    guard let gone = state.deleted[key] else { continue }
                    if kind == "run", let closed = state.runsClosedAt[id], closed > next { continue }
                    deleted[kind]!.append([
                        "kind": kind, "seq": seq, "id": id, "topic_id": gone.topicId,
                        "deleted_at": "2026-06-01T12:00:00.123456Z",
                    ])
                }
            }
            let body: [String: Any] = [
                "server_id": serverIdValue, "epoch": state.epoch, "head": head, "next": next,
                "has_more": head > next, "server_time": "2026-03-04T12:00:00Z",
                "items": items["topic"]! + items["version"]! + items["entry"]! + items["run"]!,
                "deleted": deleted["run"]! + deleted["entry"]! + deleted["version"]! + deleted["topic"]!,
            ]
            return HTTPResponse(
                status: 200, headers: [QuickrHeader.serverId: serverIdValue, QuickrHeader.epoch: state.epoch],
                body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }
    }
}

/// Parks a feed response after it was fetched (the coordinator "fetched page P, then was
/// suspended", S3), until released.
final class FeedGate: Sendable {
    private struct State {
        var armed: (@Sendable (Int) -> Bool)?
        var parked: [Int] = []
        var released = false
    }

    private let state = Mutex(State())

    /// Park the first fetch whose `after` matches (later ones pass).
    func arm(_ matches: @escaping @Sendable (Int) -> Bool) { state.withLock { $0 = State(armed: matches) } }

    func release() { state.withLock { $0.released = true } }

    var parked: [Int] { state.withLock { $0.parked } }

    func park(after: Int) async {
        let shouldPark = state.withLock { state -> Bool in
            guard let armed = state.armed, !state.released, state.parked.isEmpty, armed(after) else { return false }
            state.parked.append(after)
            return true
        }
        guard shouldPark else { return }
        while !state.withLock({ $0.released }) { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// Waits until a fetch is parked.
    func waitUntilParked() async throws {
        try await eventually("a fetch is parked") { !self.parked.isEmpty }
    }
}

/// `APIClient` over the fake transport, with an optional gate after the response arrived.
struct GatedFeed: FeedFetcher {
    let inner: APIClient
    let gate: FeedGate

    func listChanges(after cursor: Int, limit: Int, options: RequestOptions) async throws -> APIResponse<ChangePage> {
        let response = try await inner.listChanges(after: cursor, limit: limit, options: options)
        await gate.park(after: cursor)
        return response
    }
}

/// Records flush requests and events.
final class SyncRecorder: FlushRequester, SyncEventSink {
    private let state = Mutex<(flushes: [FlushRequestReason], events: [SyncEvent])>(([], []))

    var flushes: [FlushRequestReason] { state.withLock { $0.flushes } }
    var events: [SyncEvent] { state.withLock { $0.events } }

    func requestFlush(reason: FlushRequestReason) { state.withLock { $0.flushes.append(reason) } }

    func handle(_ event: SyncEvent) { state.withLock { $0.events.append(event) } }
}

/// One device: a temporary App Group directory, fake clocks, a simulated server behind
/// `FakeTransport`, and coordinators over them. `otherProcess()` opens a second registry pool
/// over the same files.
struct SyncEnv {
    static let baseURL = URL(string: "https://q.example")!

    let dir: TempDirectory
    let clock = FakeLeaseClock()
    let wall = FakeClock()
    let notifier = RecordingNotifier()
    let partitions: StorePartitions
    let server: FakeFeedServer
    let transport = FakeTransport()
    let gate = FeedGate()
    let recorder = SyncRecorder()

    init(seedFixture: Bool = true) throws {
        dir = try TempDirectory()
        partitions = try StorePartitions.open(
            at: StoreLocation(root: dir.url), leaseClock: clock, wallClock: wall, notifier: notifier)
        server = try FakeFeedServer(seedFixture: seedFixture)
        let server = server
        transport.stub(where: { $0.url.path == "/api/v1/changes" }, { try server.respond($0) })
    }

    func cleanup() { dir.cleanup() }

    func otherProcess() throws -> StorePartitions {
        try StorePartitions.open(
            at: StoreLocation(root: dir.url), leaseClock: clock, wallClock: wall, notifier: notifier)
    }

    var feed: FeedFactory {
        let transport = transport
        let gate = gate
        return { url in
            GatedFeed(
                inner: APIClient(baseURL: url, transport: transport, identity: StaticServerIdentity(nil)), gate: gate)
        }
    }

    func coordinator(
        owner: String = "app:A", partitions: StorePartitions? = nil, pageLimit: Int = 500, feed: FeedFactory? = nil,
        configure: (inout SyncCoordinator.Configuration) -> Void = { _ in }
    ) -> SyncCoordinator {
        var configuration = SyncCoordinator.Configuration()
        configuration.pageLimit = pageLimit
        configuration.autoRetry = false
        configuration.jitter = { 0 }
        configure(&configuration)
        return SyncCoordinator(
            partitions: partitions ?? self.partitions, feed: feed ?? self.feed, flush: recorder, events: recorder,
            owner: owner,
            configuration: configuration)
    }

    /// Onboards the simulated server and pulls to its head.
    @discardableResult
    func connect(_ coordinator: SyncCoordinator) async throws -> LocalStore {
        let result = await coordinator.connect(baseURL: Self.baseURL)
        guard case .connected(_, _, .synced) = result else {
            Issue.record("connect: \(result)")
            throw CancellationError()
        }
        return try await activeStore()
    }

    /// The active store as another process would open it.
    func activeStore() async throws -> LocalStore {
        try #require(try await partitions.openActiveStore(role: .extension)).store
    }

    /// `after` of every feed request since `index`.
    func afters(from index: Int = 0) -> [Int] {
        transport.requests.dropFirst(index).compactMap { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "after" }?.value.flatMap(Int.init)
        }
    }
}

extension LocalStore {
    func state() async throws -> SyncState { try #require(try await syncState.syncState()) }

    func count(_ table: String, _ condition: String = "1") async throws -> Int {
        try await writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(condition)") ?? 0
        }
    }

    func ids(_ table: String) async throws -> Set<String> {
        try await writer.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM \(table)")) }
    }

    /// Every row of the server layer, staging and sync_state, for "nothing was written".
    func fingerprint() async throws -> String {
        try await writer.read { db in
            var out = ""
            for table in StoreSchema.serverLayerTables + StoreSchema.stageTables + [
                "sync_state", "stage_state", "outbox_item",
            ] {
                out += "\(table): \(try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2"))\n"
            }
            return out
        }
    }

    @discardableResult
    func enqueue(_ payload: OutboxPayload, id: UUID = UUID(), hold: LeaseInstant? = nil) async throws -> OutboxItem {
        try await outbox.appendRawForTesting(NewOutboxItem(id: id, payload: payload, origin: .app, hold: hold))
    }

    func setItemState(_ id: String, _ state: OutboxState) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE outbox_item SET state = ? WHERE id = ?", arguments: [state.rawValue, id])
        }
    }

    func item(_ id: String) async throws -> OutboxItem? {
        try await writer.read { db in try OutboxStorage.item(db, id: id) }
    }
}

/// Polls `condition` until it holds, failing after `timeout`: a liveness ceiling, generous because
/// a loaded machine can delay any task; never the timing under test.
func eventually(
    _ what: String, timeout: Duration = .seconds(120), _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting until \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Awaits `work`, failing after `timeout` if it hasn't returned, so a wait that a regression
/// deadlocks becomes a recorded issue in seconds instead of a hung job. The work runs in a task
/// of its own and is abandoned on timeout, so it never holds the test up.
func within<T: Sendable>(
    _ what: String, timeout: Duration = .seconds(120), _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = Mutex<Result<T, any Error>?>(nil)
    let finished = Mutex(false)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let finish: @Sendable (Result<T, any Error>?) -> Void = { result in
            let first = finished.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else { return }
            outcome.withLock { $0 = result }
            continuation.resume()
        }
        Task {
            do { finish(.success(try await work())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            finish(nil)
        }
    }
    guard let result = outcome.withLock({ $0 }) else {
        Issue.record("timed out after \(timeout) waiting until \(what)")
        throw CancellationError()
    }
    return try result.get()
}

enum Payloads {
    static let water = TopicRef(id: UUID(uuidString: FakeFeedServer.water)!, slug: "water", name: "Water")

    static func create(topic: TopicRef = water, glasses: Int = 2) -> OutboxPayload {
        .entryCreate(
            topic: topic,
            body: EntryCreateDTO(
                id: nil, answers: ["glasses": .int(glasses)], source: "ios", capturedAt: Make.t0, version: 1))
    }

    static func update(_ entryId: String, topicId: String = FakeFeedServer.water, glasses: Int = 5) -> OutboxPayload {
        .entryUpdate(entryId: entryId, topicId: topicId, patch: EntryUpdateDTO(answers: ["glasses": .int(glasses)]))
    }

    static func delete(_ entryId: String, topicId: String = FakeFeedServer.water) -> OutboxPayload {
        .entryDelete(entryId: entryId, topicId: topicId)
    }
}
