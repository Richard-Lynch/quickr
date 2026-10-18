// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// The multi-process tests (sync-protocol.md §13 G5, outbox.md §13, notifications.md N4): real
/// `ProcessHelper agent` child processes on shared, file-backed stores, stopped with SIGSTOP and
/// killed with SIGKILL. Every barrier is a reply line from a child or a request arriving at the
/// fake server (`Gate.arrival`); lease time and the wall clock are shared files the test moves.
/// The suite runs serially: children are heavy, and several share one loopback server per test.
@Suite(.serialized, .timeLimit(.minutes(3))) struct MultiProcessTests {}

/// One multi-process test's world: a temporary App Group directory with the registry and store
/// files, the shared clocks, a fake server reachable over loopback HTTP, and the children.
final class MPWorld: @unchecked Sendable {
    let dir: TempDirectory
    let leaseClock: FileLeaseClock
    let wall: FileWallClock
    let scope = "mp-\(UUID().uuidString.prefix(8))"
    let partitions: StorePartitions
    let http: TransportHTTPServer
    private let children = Mutex<[HelperProcess]>([])
    private let gates = Mutex<[Gate]>([])

    var root: URL { dir.url }
    var baseURL: URL { http.baseURL }

    init(serving transport: any Transport) async throws {
        dir = try TempDirectory()
        leaseClock = try FileLeaseClock.create(at: dir.url.appending(path: "lease-clock"))
        wall = try FileWallClock.create(at: dir.url.appending(path: "wall-clock"), date: Make.t0)
        partitions = try StorePartitions.open(
            at: StoreLocation(root: dir.url), leaseClock: leaseClock, wallClock: wall,
            notifier: ScopedDarwinNotifier(scope: scope))
        http = try await TransportHTTPServer(serving: transport)
    }

    /// Launches a child as `owner` (`app:…` or `widget:…`) and, unless `open` is nil, opens the
    /// active store in it with that role.
    func spawn(
        _ owner: String, open role: String? = "app", leaseClock: String? = nil, pageLimit: Int? = nil
    ) async throws -> HelperProcess {
        var arguments = [
            "--root", dir.url.path, "--owner", owner, "--lease-clock", leaseClock ?? self.leaseClock.url.path,
            "--wall-clock", wall.url.path, "--scope", scope,
        ]
        if let pageLimit { arguments += ["--page-limit", String(pageLimit)] }
        let child = try HelperProcess(name: owner, arguments: arguments)
        children.withLock { $0.append(child) }
        _ = try await child.run("ping")
        if let role { try await child.run("open", ["role": role]) }
        return child
    }

    /// A gate that `shutdown` opens, so a failed test never leaves a request, a server handler or
    /// an `arrived()` waiter blocked on it.
    func gate() -> Gate {
        let gate = Gate()
        gates.withLock { $0.append(gate) }
        return gate
    }

    func shutdown() async {
        for child in children.withLock({ $0 }) where child.isRunning {
            child.resume()
            await child.killNow()
        }
        for gate in gates.withLock({ $0 }) { gate.releaseAll() }
        await http.stop()
        dir.cleanup()
    }

    /// The active store as the test process sees it.
    func activeStore() async throws -> LocalStore {
        try #require(try await partitions.openActiveStore(role: .extension)).store
    }

    func server(_ serverId: String) async throws -> RegisteredServer {
        try #require(try await partitions.registry.repository.server(id: serverId))
    }
}

protocol MPWorldOwner: Sendable { var world: MPWorld { get } }

extension MPWorldOwner {
    /// Runs `body` and always tears the world down (children killed, files removed).
    func running(_ body: (Self) async throws -> Void) async throws {
        do {
            try await body(self)
        } catch {
            await world.shutdown()
            throw error
        }
        await world.shutdown()
    }
}

// MARK: - Outbox world

/// outbox.md §13 world: `FakeServer` (identity `server-1`/`E1`) over loopback HTTP; one store
/// `server-1` registered and active, bootstrapped with topic `T` in its server layer.
final class OutboxWorld: MPWorldOwner, @unchecked Sendable {
    let world: MPWorld
    let server = FakeServer()
    let store: LocalStore
    let topic: Topic

    init(topicRevision: Int = 1, topicStatus: TopicStatus = .active) async throws {
        world = try await MPWorld(serving: server)
        topic = Make.topic(revision: topicRevision, status: topicStatus)
        server.put(topic)
        store = try await world.partitions.createStore(serverId: "server-1", baseURL: world.baseURL.absoluteString)
        try await world.partitions.registry.setActive("server-1")
        let topic = topic
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            _ = try ServerLayer.upsert(db, topic: topic)
        }
    }

    static func run(
        topicRevision: Int = 1, topicStatus: TopicStatus = .active, _ body: (OutboxWorld) async throws -> Void
    ) async throws {
        try await OutboxWorld(topicRevision: topicRevision, topicStatus: topicStatus).running(body)
    }

    var topicArgs: [String: String] {
        ["topicId": topic.id.wireString, "slug": topic.slug, "name": topic.name]
    }

    var items: [OutboxItem] { (try? store.writer.read { db in try OutboxStorage.items(db) }) ?? [] }

    func item(_ id: UUID) -> OutboxItem? {
        try? store.writer.read { db in try OutboxStorage.item(db, id: id.wireString) }
    }

    /// The rows a superseded or dead sender must not touch.
    func snapshot() throws -> [String] {
        try store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM outbox_item ORDER BY seq").map(\.description)
                + Row.fetchAll(db, sql: "SELECT * FROM entry ORDER BY id").map(\.description)
        }
    }

    func seedEntry(revision: Int = 1, notes: String = "") throws -> Entry {
        let entry = Make.entry(topicId: topic.id, revision: revision, notes: notes)
        server.put(entry)
        try store.writer.write { db in _ = try ServerLayer.upsert(db, entry: entry) }
        return entry
    }

    /// Logs a new entry in `child`; returns its id.
    func log(_ child: HelperProcess) async throws -> UUID {
        let id = UUID()
        try await child.run("log", topicArgs.merging(["id": id.wireString]) { $1 })
        return id
    }
}

// MARK: - Sync world

/// sync-protocol.md §13 world: the change feed (`FakeFeedServer`) and, for outbox sends, a
/// `FakeServer` with the same identity, behind one loopback server. Feed requests can be held
/// by `holdFeed`, and every feed request's `after` is recorded in order.
final class SyncWorld: MPWorldOwner, @unchecked Sendable {
    let world: MPWorld
    let feed: FakeFeedServer
    let api = FakeServer()
    let router: SyncRouter

    init() async throws {
        feed = try FakeFeedServer()
        api.with {
            $0.serverId = FakeFeedServer.defaultServerId
            $0.epoch = FakeFeedServer.fixtureEpoch
        }
        router = SyncRouter(feed: feed, api: api)
        world = try await MPWorld(serving: router)
    }

    static func run(_ body: (SyncWorld) async throws -> Void) async throws {
        try await SyncWorld().running(body)
    }

    /// Onboards the server from the test process (§2.1) and pulls to its head.
    @discardableResult
    func connect() async throws -> LocalStore {
        let coordinator = SyncCoordinator(
            partitions: world.partitions,
            feed: { url in
                APIClient(baseURL: url, transport: URLSessionTransport(), identity: StaticServerIdentity(nil))
            },
            flush: NoSyncSideEffects(), owner: "app:setup",
            configuration: {
                var configuration = SyncCoordinator.Configuration()
                configuration.autoRetry = false
                return configuration
            }())
        let result = await coordinator.connect(baseURL: world.baseURL)
        guard case .connected(_, _, .synced) = result else {
            throw HelperError(description: "connect: \(result)")
        }
        return try await world.activeStore()
    }

    /// Both servers move to `epoch` (a restore with `make rotate-epoch`).
    func rotateEpoch(to epoch: String) {
        feed.rotateEpoch(to: epoch)
        api.with { $0.epoch = epoch }
    }

    var afters: [Int] { router.afters }
}

/// Routes `/api/v1/changes` to the feed (optionally held at a `Gate`) and everything else to the
/// API fake.
final class SyncRouter: Transport {
    private let feed: FakeFeedServer
    private let api: FakeServer
    private let state = Mutex<(afters: [Int], holds: [(matches: @Sendable (Int) -> Bool, gate: Gate)])>(([], []))

    init(feed: FakeFeedServer, api: FakeServer) {
        self.feed = feed
        self.api = api
    }

    var afters: [Int] { state.withLock { $0.afters } }

    /// Holds the next feed request whose `after` matches until `gate` opens.
    func holdFeed(where matches: @escaping @Sendable (Int) -> Bool, at gate: Gate) {
        state.withLock { $0.holds.append((matches, gate)) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.path == "/api/v1/changes" else { return try await api.send(request) }
        let after =
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "after" }?.value.flatMap(Int.init) ?? 0
        let gate = state.withLock { state -> Gate? in
            state.afters.append(after)
            guard let index = state.holds.firstIndex(where: { $0.matches(after) }) else { return nil }
            return state.holds.remove(at: index).gate
        }
        // The page is built when the request arrives (what A "fetched"); the answer is held.
        let response = try feed.respond(request)
        if let gate { await gate.arrive() }
        return response
    }
}

extension Gate {
    /// `arrival()` as a barrier that fails the test after `timeout` instead of hanging when the
    /// request never comes (a broken process never sends it).
    func arrived(within timeout: Duration = .seconds(30)) async throws {
        let flag = ArrivalFlag()
        Task { [self] in
            await arrival()
            flag.set()
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !flag.isSet {
            guard ContinuousClock.now < deadline else {
                throw HelperError(description: "no request arrived at the gate within \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private final class ArrivalFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() { value.withLock { $0 = true } }
}

extension LocalStore {
    func mpState() async throws -> SyncState { try #require(try await syncState.syncState()) }
}
#endif
