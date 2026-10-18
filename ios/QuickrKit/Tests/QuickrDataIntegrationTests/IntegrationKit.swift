import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// The harness's environment (ios/README.md "Integration tests"), read once. Nil when any variable
/// is missing: plain `swift test` skips the suite; `make ios-integration` sets
/// QUICKR_IT_REQUIRED=1 and `IntegrationHarnessTests` fails instead.
struct ITConfig: Sendable {
    var proxyURL: URL
    var serverBURL: URL
    var serverAURL: URL
    var controlURL: URL
    var serverId: String
    var serverIdB: String
    var rotateEpoch: String

    static let current: ITConfig? = {
        let env = ProcessInfo.processInfo.environment
        func url(_ name: String) -> URL? { env[name].flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        func text(_ name: String) -> String? { env[name].flatMap { $0.isEmpty ? nil : $0 } }
        guard let proxy = url("QUICKR_IT_BASE_URL"), let b = url("QUICKR_IT_BASE_URL_2"),
            let a = url("QUICKR_IT_DIRECT_URL"), let control = url("QUICKR_IT_PROXY_CONTROL_URL"),
            let id = text("QUICKR_IT_SERVER_ID"), let idB = text("QUICKR_IT_SERVER_ID_2"),
            let rotate = text("QUICKR_IT_ROTATE_EPOCH")
        else { return nil }
        return ITConfig(
            proxyURL: proxy, serverBURL: b, serverAURL: a, controlURL: control, serverId: id, serverIdB: idB,
            rotateEpoch: rotate)
    }()

    static var isRequired: Bool { ProcessInfo.processInfo.environment["QUICKR_IT_REQUIRED"] == "1" }

    static func require() throws -> ITConfig {
        try #require(current, "the integration environment is not set (run make ios-integration)")
    }
}

/// Plain JSON over HTTP with no quickR client code: the fault proxy's control API, and the
/// servers as the web app reaches them, to seed data and to check server state independently of
/// the code under test.
struct HTTP: Sendable {
    struct Reply: @unchecked Sendable {
        var status: Int
        var headers: [String: String]
        var json: Any?

        var object: [String: Any] { json as? [String: Any] ?? [:] }
        var array: [[String: Any]] { json as? [[String: Any]] ?? [] }
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    let base: URL

    @discardableResult
    func call(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Reply {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        return Reply(status: http.statusCode, headers: headers, json: json)
    }
}

/// The fault proxy's control API (backend/tools/faultproxy.py).
struct FaultProxy: Sendable {
    let http: HTTP

    /// Removes every rule (releasing held requests), clears the log and routes to server a.
    func reset() async throws {
        let reply = try await http.call("POST", "/reset")
        try #require(reply.status == 200, "proxy reset: \(reply.status)")
    }

    /// Installs a rule and returns its id.
    @discardableResult
    func add(_ rule: [String: Any]) async throws -> Int {
        let reply = try await http.call("POST", "/rules", rule)
        try #require(reply.status == 201, "proxy rule \(rule): \(reply.status) \(reply.object)")
        return try #require(reply.object["id"] as? Int)
    }

    func rule(_ id: Int) async throws -> [String: Any] { try await http.call("GET", "/rules/\(id)").object }

    /// Waits until the rule holds a request (`hold`).
    func waitUntilHolding(_ id: Int) async throws {
        try await eventually("rule \(id) holds a request", timeout: .seconds(20)) {
            (try await rule(id)["waiting"] as? Int ?? 0) >= 1
        }
    }

    /// Lets a `hold` rule's parked requests (and any later ones) through.
    func release(_ id: Int) async throws {
        let reply = try await http.call("POST", "/rules/\(id)/release")
        try #require(reply.status == 200, "release \(id): \(reply.status)")
    }

    func log() async throws -> [ProxyLogEntry] {
        try await http.call("GET", "/log").array.map(ProxyLogEntry.init)
    }

    func route(to upstream: String) async throws {
        let reply = try await http.call("PUT", "/upstream", ["name": upstream])
        try #require(reply.status == 200, "upstream \(upstream): \(reply.status)")
    }
}

/// One request the proxy saw.
struct ProxyLogEntry: Sendable, CustomStringConvertible {
    var method: String
    var path: String
    var action: String
    /// Server a or b; nil when the proxy answered itself or dropped the request.
    var upstream: String?
    var upstreamStatus: Int?
    var status: Int?
    var state: String

    init(_ json: [String: Any]) {
        method = json["method"] as? String ?? ""
        path = json["path"] as? String ?? ""
        action = json["action"] as? String ?? ""
        upstream = json["upstream"] as? String
        upstreamStatus = json["upstream_status"] as? Int
        status = json["status"] as? Int
        state = json["state"] as? String ?? ""
    }

    /// The path without its query.
    var route: String { String(path.prefix { $0 != "?" }) }

    var description: String {
        "\(method) \(path) [\(action)] → \(upstream ?? "-"):\(upstreamStatus.map(String.init) ?? "-") \(state)"
    }
}

/// A quickR server as the web app reaches it.
struct WebServer: Sendable {
    let http: HTTP

    /// Creates a topic with one optional whole-number question `n` (0–100) and returns its ref.
    func createTopic(_ name: String = "IT \(UUID().uuidString.prefix(8))") async throws -> TopicRef {
        let reply = try await http.call(
            "POST", "/api/v1/topics",
            [
                "name": name,
                "questions": [["key": "n", "label": "N", "type": "int", "min": 0, "max": 100, "required": false]],
            ])
        try #require(reply.status == 201, "create topic: \(reply.status) \(reply.object)")
        let id = try #require((reply.object["id"] as? String).flatMap(UUID.init))
        return TopicRef(id: id, slug: try #require(reply.object["slug"] as? String), name: name)
    }

    /// Logs an entry from the web and returns its id.
    @discardableResult
    func createEntry(topic: TopicRef, n: Int = 1, id: UUID = UUID()) async throws -> UUID {
        let reply = try await http.call(
            "POST", "/api/v1/topics/\(topic.id)/entries",
            ["id": id.wireString, "answers": ["n": n], "captured_at": WireDate.format(Date())])
        try #require(reply.status == 201, "create entry: \(reply.status) \(reply.object)")
        return id
    }

    func updateEntry(_ id: UUID, n: Int) async throws {
        let reply = try await http.call("PATCH", "/api/v1/entries/\(id.wireString)", ["answers": ["n": n]])
        try #require(reply.status == 200, "update entry: \(reply.status) \(reply.object)")
    }

    func deleteEntry(_ id: UUID) async throws {
        let reply = try await http.call("DELETE", "/api/v1/entries/\(id.wireString)")
        try #require(reply.status == 204, "delete entry: \(reply.status) \(reply.object)")
    }

    /// Deletes a topic from the web: archive, then delete (an unarchived topic can't be deleted).
    func deleteTopic(_ topic: TopicRef) async throws {
        let archived = try await http.call("POST", "/api/v1/topics/\(topic.id)/archive")
        try #require(archived.status == 200, "archive topic: \(archived.status) \(archived.object)")
        let deleted = try await http.call("DELETE", "/api/v1/topics/\(topic.id)")
        try #require(deleted.status == 204, "delete topic: \(deleted.status) \(deleted.object)")
    }

    /// The entry as the server has it, or nil (404).
    func entry(_ id: UUID) async throws -> [String: Any]? {
        let reply = try await http.call("GET", "/api/v1/entries/\(id.wireString)")
        if reply.status == 404 { return nil }
        try #require(reply.status == 200, "get entry: \(reply.status)")
        return reply.object
    }

    /// The whole-number answer `key` of a server entry (answers are `[{key, type, value}]`).
    static func answer(_ entry: [String: Any]?, _ key: String = "n") -> Int? {
        (entry?["answers"] as? [[String: Any]])?.first { $0["key"] as? String == key }?["value"] as? Int
    }

    /// The server's identity headers, from a health check.
    func identity() async throws -> ServerIdentity {
        let reply = try await http.call("GET", "/api/v1/health")
        return ServerIdentity(
            serverId: try #require(reply.header(QuickrHeader.serverId)),
            epoch: try #require(reply.header(QuickrHeader.epoch)))
    }

    /// What the server's feed says is live: entry id → revision, and topic ids (deletions
    /// applied in `seq` order).
    func live() async throws -> (entries: [String: Int], topics: Set<String>) {
        var after = 0
        var changes: [(seq: Int, kind: String, id: String, revision: Int?, deleted: Bool)] = []
        while true {
            let page = try await http.call("GET", "/api/v1/changes?after=\(after)&limit=500").object
            for item in page["items"] as? [[String: Any]] ?? [] {
                let kind = item["kind"] as? String ?? ""
                let body = item[kind] as? [String: Any] ?? item
                changes.append(
                    (item["seq"] as? Int ?? 0, kind, body["id"] as? String ?? "", body["revision"] as? Int, false))
            }
            for item in page["deleted"] as? [[String: Any]] ?? [] {
                changes.append(
                    (item["seq"] as? Int ?? 0, item["kind"] as? String ?? "", item["id"] as? String ?? "", nil, true))
            }
            after = page["next"] as? Int ?? after
            if page["has_more"] as? Bool != true { break }
        }
        var entries: [String: Int] = [:]
        var topics = Set<String>()
        for change in changes.sorted(by: { $0.seq < $1.seq }) {
            switch (change.kind, change.deleted) {
            case ("entry", false): entries[change.id] = change.revision
            case ("entry", true): entries[change.id] = nil
            case ("topic", false): topics.insert(change.id)
            case ("topic", true): topics.remove(change.id)
            default: break
            }
        }
        return (entries, topics)
    }
}

/// Records every request the client sends (body and headers included), then sends it for real.
final class RecordingTransport: Transport {
    private let inner: any Transport
    private let sent = Mutex<[HTTPRequest]>([])

    init(_ inner: any Transport = URLSessionTransport()) { self.inner = inner }

    var requests: [HTTPRequest] { sent.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.withLock { $0.append(request) }
        return try await inner.send(request)
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

/// One phone: its own App Group directory over the real backend, with the production wiring of
/// the coordinator, the outbox, its scheduler and the two bridges between them. Lease time is a
/// `FakeLeaseClock` (TTLs and backoff are advanced by hand); wall time is real, because the server
/// validates `captured_at`.
final class Device: Sendable {
    let config: ITConfig
    let dir: URL
    let clock = FakeLeaseClock()
    let partitions: StorePartitions
    let transport = RecordingTransport()
    let bridge = OutboxFlushBridge()
    let coordinator: SyncCoordinator

    init(_ config: ITConfig, pageLimit: Int = APIClient.feedPageLimit) throws {
        self.config = config
        dir = FileManager.default.temporaryDirectory.appending(path: "quickr-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No notifier: Darwin notifications are global to the Mac and would cross worktrees.
        partitions = try StorePartitions.open(
            at: StoreLocation(root: dir), leaseClock: clock, wallClock: SystemWallClock(), notifier: nil)
        coordinator = Self.coordinator(
            partitions: partitions, transport: transport, bridge: bridge, pageLimit: pageLimit)
    }

    /// Another launch of the app over the same files: a new coordinator (and outbox) process.
    func relaunch(pageLimit: Int = APIClient.feedPageLimit) throws -> SyncCoordinator {
        let partitions = try StorePartitions.open(
            at: StoreLocation(root: dir), leaseClock: clock, wallClock: SystemWallClock(), notifier: nil)
        return Self.coordinator(partitions: partitions, transport: transport, bridge: bridge, pageLimit: pageLimit)
    }

    private static func coordinator(
        partitions: StorePartitions, transport: RecordingTransport, bridge: OutboxFlushBridge, pageLimit: Int
    ) -> SyncCoordinator {
        var configuration = SyncCoordinator.Configuration()
        configuration.pageLimit = pageLimit
        configuration.autoRetry = false
        configuration.jitter = { 0 }
        return SyncCoordinator(
            partitions: partitions,
            feed: { url in APIClient(baseURL: url, transport: transport, identity: StaticServerIdentity(nil)) },
            flush: bridge, owner: "app:A", configuration: configuration)
    }

    /// Teardown: unbinds the bridge (retiring the bound scheduler, which cancels a running flush and
    /// refuses later requests), then deletes the files. `IT.withDevice` and `Device.run` call it on
    /// every path.
    func shutdown() async {
        await bridge.bind(nil)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Runs `body`, then `shutdown()`, whether `body` returns or throws.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            await shutdown()
            return result
        } catch {
            await shutdown()
            throw error
        }
    }

    /// Onboards the proxy's server (a) and pulls to its head.
    @discardableResult
    func connect() async throws -> LocalStore {
        let result = await coordinator.connect(baseURL: config.proxyURL)
        guard case .connected(let serverId, _, .synced) = result else {
            Issue.record("connect: \(result)")
            throw CancellationError()
        }
        #expect(serverId == config.serverId)
        return try await store()
    }

    /// The active store, opened as a second process would.
    func store() async throws -> LocalStore {
        try #require(try await partitions.openActiveStore(role: .extension)).store
    }

    /// The app's outbox for the active store: sends through the proxy, signals the coordinator.
    func outbox(owner: String = "app:A") async throws -> Outbox {
        Outbox(
            store: try await store(),
            sender: APIClient(baseURL: config.proxyURL, transport: transport, identity: StaticServerIdentity(nil)),
            owner: owner, onSignal: coordinator.outboxSignalHandler)
    }

    /// The outbox's scheduler, bound to the coordinator's flush bridge (as the app wires it).
    func scheduler(_ outbox: Outbox) async -> OutboxFlushScheduler {
        let scheduler = OutboxFlushScheduler(outbox: outbox)
        await bridge.bind(scheduler)
        return scheduler
    }

    /// Every request this device sent, after `index`.
    func sent(from index: Int = 0, _ method: HTTPMethod? = nil) -> [HTTPRequest] {
        transport.requests.dropFirst(index).filter { method == nil || $0.method == method }
    }
}

extension LocalStore {
    func state() async throws -> SyncState { try #require(try await syncState.syncState()) }

    func item(_ id: String) async throws -> OutboxItem? {
        try await writer.read { db in try OutboxStorage.item(db, id: id) }
    }

    func item(_ id: UUID) async throws -> OutboxItem? { try await item(id.wireString) }

    var items: [OutboxItem] {
        get async throws {
            try await writer.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM outbox_item ORDER BY seq").compactMap {
                    try OutboxStorage.item(db, id: $0)
                }
            }
        }
    }

    /// The entry as this device shows it (server layer plus pending edits), or nil.
    func view(_ id: UUID) async throws -> ViewEntry? {
        try await writer.read { db in try StoreView.entry(db, id: id.wireString) }
    }

    /// The server layer's revision of an entry, nil when it has none.
    func serverRevision(_ id: UUID) async throws -> Int? {
        try await writer.read { db in try ServerLayer.revision(db, entityKind: .entry, id: id.wireString) }
    }

    func isTombstoned(_ id: UUID) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM tombstone WHERE id = ?)", arguments: [id.wireString])
                ?? false
        }
    }

    /// Server-layer entries: id → revision.
    func entryRevisions() async throws -> [String: Int] {
        try await writer.read { db in
            Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, revision FROM entry").map {
                    ($0["id"] as String, $0["revision"] as Int)
                })
        }
    }

    func topicIds() async throws -> Set<String> {
        try await writer.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM topic")) }
    }
}

/// An entry body as the app logs it: `n` now.
func logBody(n: Int = 1) -> EntryCreateDTO {
    EntryCreateDTO(id: nil, answers: ["n": .int(n)], source: nil, capturedAt: Date(), version: 1)
}

/// Polls `condition` until it holds, failing after `timeout`.
func eventually(
    _ what: String, timeout: Duration = .seconds(30), _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting until \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// Runs the harness's epoch rotation for server a or b and returns the new epoch.
func rotateEpoch(_ config: ITConfig, server: String = "a") async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: config.rotateEpoch)
    process.arguments = [server]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let exited = AsyncStream<Void> { continuation in
        process.terminationHandler = { _ in continuation.finish() }
    }
    try process.run()
    for await _ in exited {}
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try #require(process.terminationStatus == 0, "rotate epoch \(server): \(text)")
    let base = server == "a" ? config.serverAURL : config.serverBURL
    return try await WebServer(http: HTTP(base: base)).identity().epoch
}
