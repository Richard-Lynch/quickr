#if DEBUG
import Foundation
import QuickrCore
import QuickrData
import Synchronization

/// `-QuickrUITest` (DEBUG only): a clean slate for a UI test, so it never touches the real store,
/// settings or Keychain. A fresh store directory and defaults suite per launch, an in-memory
/// Keychain, and a fake quickR server at `https://quickr.test`; any other host goes to the
/// network, so a test can also onboard against the integration stack.
///
/// With it:
/// - `-QuickrServer <url>` presets the server (launch connects, skipping onboarding);
/// - `-QuickrOpen <url>` opens a link once the root is up (screenshots, deep-link checks);
/// - `-QuickrSeedRejectedEntry` first queues a Workout entry the server refuses (duration 900),
///   with the id `rejectedEntryId`, and waits until it has failed (fix mode);
/// - `-QuickrStalePublish`: someone else publishes a version of the topic just before this
///   device's first version check or publish, which therefore conflicts (409);
/// - `-QuickrSyncControls` shows `UITestSyncControls` (go offline or online, log an entry, reject
///   the next one) for the sync UI tests. The network path is `UITestLaunch.network`, which the
///   controls switch together with the fake server.
enum UITestLaunch {
    static let argument = "-QuickrUITest"
    static let fakeServer = URL(string: "https://quickr.test")!
    static let fakeServerId = "00000000-0000-4000-8000-0000000000aa"
    static let rejectedEntryId = UUID(uuidString: "0f1e2d3c-4b5a-4968-8778-0000000000f1")!

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-QuickrSyncControls`, when testing.
    static var showsSyncControls: Bool { isActive && ProcessInfo.processInfo.arguments.contains("-QuickrSyncControls") }

    /// The fake server's switches.
    static let server = FakeServerState()
    /// The network path the app sees while testing.
    static let network = DebugNetworkMonitor()

    /// `categoryCenter: nil` for unit tests: the system's category set is one per process, and
    /// tests running alongside the categories' own would replace it.
    /// - Parameter notificationCenter: GRDB's suspend and resume (see `AppEnvironment.live`):
    ///   hosted tests that background the session pass their own.
    @MainActor static func environment(
        categoryCenter: (any NotificationCenterProtocol)? = SystemNotificationCenter(),
        notificationCenter: NotificationCenter = .default
    ) -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-uitest-\(UUID().uuidString)")
        let suite = "quickr.uitest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let environment = AppEnvironment.live(
            location: StoreLocation(root: root), defaults: defaults, keychain: InMemoryKeychain(),
            transport: FakeServerTransport(fallback: URLSessionTransport(), state: server), network: network,
            categoryCenter: categoryCenter, notificationCenter: notificationCenter)
        environment.settings.serverURL = value(after: "-QuickrServer").flatMap(URL.init(string:))
        if ProcessInfo.processInfo.arguments.contains("-QuickrStalePublish") { server.publishElsewhereFirst() }
        return environment
    }

    /// `-QuickrOpen <url>`, when testing (a clean slate or the demo store).
    static var openURL: URL? {
        guard isActive || DemoStore.isRequested else { return nil }
        return value(after: "-QuickrOpen").flatMap(URL.init(string:))
    }

    /// Before `-QuickrOpen`: the seeds the launch asked for. Bounded: gives up after 20 s.
    @MainActor static func prepare(_ environment: AppEnvironment) async {
        guard isActive, ProcessInfo.processInfo.arguments.contains("-QuickrSeedRejectedEntry") else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        func waitFor(_ condition: () async -> Bool) async -> Bool {
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        guard await waitFor({ environment.session?.outbox != nil }), let session = environment.session,
            let outbox = session.outbox, let store = session.store
        else { return }
        let body = EntryCreateDTO(
            id: nil, answers: ["type": .string("run"), "duration": .int(900)], source: nil,
            capturedAt: Date().addingTimeInterval(-3600), notes: "Long run", version: 1)
        try? await outbox.createEntry(
            id: rejectedEntryId, topic: TopicRef(id: FakeServer.workoutId, slug: "workout", name: "Workout"),
            body: body,
            origin: .app)
        await session.scheduler?.requestFlush(reason: .enqueue)
        _ = await waitFor { (try? await store.outbox.item(id: rejectedEntryId.wireString))?.state == .failed }
    }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// The fake server's switches: unreachable, whether the next create is rejected (422), and
/// whether feed requests are held (unit tests of interrupted startups). Counts requests.
final class FakeServerState: Sendable {
    private struct State {
        var offline = false
        var rejectNext = false
        var holdFeed = false
        var requests = 0
        var cancelled = 0
        var holdCancellations = false
        var unwinding: [CheckedContinuation<Void, any Error>] = []
        var held: [UUID: CheckedContinuation<Void, any Error>] = [:]
        /// Topics as the server holds them now (`TopicDetail` JSON), after the online-only writes
        /// and archives the tests made (TOPIC). Seeded with the feed's two.
        var topics: [String: Data] = FakeServer.seedTopics()
        /// Feed items after the seeded page (seq 5, 6, …): the topic and version rows of the
        /// versions published here, as the change feed lists them.
        var feed: [String] = []
        var publishElsewhere = false
    }

    private let state = Mutex(State())

    var offline: Bool {
        get { state.withLock { $0.offline } }
        set { state.withLock { $0.offline = newValue } }
    }

    /// Requests that reached the server (any host path), held ones included.
    var requestCount: Int { state.withLock { $0.requests } }

    /// Feed requests waiting while `holdFeed` is on.
    var heldCount: Int { state.withLock { $0.held.count } }

    /// Held feed requests that were cancelled while waiting.
    var cancelledCount: Int { state.withLock { $0.cancelled } }

    func rejectNextCreate() { state.withLock { $0.rejectNext = true } }

    /// Whether this create is rejected (the flag is used once).
    func takeReject() -> Bool {
        state.withLock { state in
            defer { state.rejectNext = false }
            return state.rejectNext
        }
    }

    /// Holds feed requests until `releaseFeed()` (a cancelled one stops waiting, as URLSession's does).
    func holdFeed() { state.withLock { $0.holdFeed = true } }

    /// A cancelled held request also waits, until `releaseFeed()`: the cancelled work is still
    /// unwinding meanwhile (a slow URLSession cancel).
    func holdCancellations() { state.withLock { $0.holdCancellations = true } }

    func releaseFeed() {
        let (waiters, cancelled) = state.withLock { state in
            state.holdFeed = false
            state.holdCancellations = false
            defer {
                state.held = [:]
                state.unwinding = []
            }
            return (Array(state.held.values), state.unwinding)
        }
        for waiter in waiters { waiter.resume() }
        for waiter in cancelled { waiter.resume(throwing: TransportError.cancelled(requestStarted: true)) }
    }

    fileprivate func counted() { state.withLock { $0.requests += 1 } }

    fileprivate func topic(_ id: String) -> [String: Any]? {
        state.withLock { $0.topics[id] }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    fileprivate func put(_ topic: [String: Any]) {
        guard let id = topic["id"] as? String, let data = try? JSONSerialization.data(withJSONObject: topic) else {
            return
        }
        state.withLock { $0.topics[id] = data }
    }

    fileprivate func removeTopic(_ id: String) { _ = state.withLock { $0.topics.removeValue(forKey: id) } }

    /// `-QuickrStalePublish`.
    func publishElsewhereFirst() { state.withLock { $0.publishElsewhere = true } }

    /// Whether someone else publishes first (the flag is used once).
    fileprivate func takePublishElsewhere() -> Bool {
        state.withLock { state in
            defer { state.publishElsewhere = false }
            return state.publishElsewhere
        }
    }

    /// Publishes `questions` as the topic's next version: the topic row and the version row go
    /// into the feed. Returns the updated topic.
    fileprivate func publish(_ id: String, questions: [[String: Any]], note: String) -> [String: Any]? {
        guard var topic = topic(id) else { return nil }
        let now = ISO8601DateFormatter().string(from: Date())
        let number = (topic["current_version"] as? Int ?? 1) + 1
        topic["current_version"] = number
        topic["questions"] = questions
        topic["question_count"] = questions.count
        topic["revision"] = (topic["revision"] as? Int ?? 1) + 1
        topic["updated_at"] = now
        let version: [String: Any] = [
            "version": number, "questions": questions, "change_note": note, "created_at": now, "entry_count": 0,
        ]
        put(topic)
        state.withLock { state in
            let seq = 5 + state.feed.count
            let items: [[String: Any]] = [
                ["kind": "topic", "seq": seq, "topic": topic],
                [
                    "kind": "version", "seq": seq + 1, "id": UUID().wireString, "topic_id": id,
                    "version": version,
                ],
            ]
            for item in items {
                guard let data = try? JSONSerialization.data(withJSONObject: item) else { continue }
                state.feed.append(String(decoding: data, as: UTF8.self))
            }
        }
        return topic
    }

    /// The feed items after `cursor`, and the head.
    fileprivate func feed(after cursor: Int) -> (items: [String], head: Int) {
        state.withLock { state in
            let head = 4 + state.feed.count
            return (Array(state.feed.dropFirst(max(0, cursor - 4))), head)
        }
    }

    fileprivate func slugTaken(_ slug: String, except id: String?) -> Bool {
        state.withLock { state in
            state.topics.contains { key, data in
                key != id
                    && (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["slug"] as? String == slug
            }
        }
    }

    fileprivate func waitIfFeedHeld() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let proceed = state.withLock { state -> Bool in
                    guard state.holdFeed, !Task.isCancelled else { return true }
                    state.held[id] = continuation
                    return false
                }
                if proceed { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let waiter = state.held.removeValue(forKey: id) else { return nil }
                state.cancelled += 1
                guard !state.holdCancellations else {
                    state.unwinding.append(waiter)
                    return nil
                }
                return waiter
            }
            waiter?.resume(throwing: TransportError.cancelled(requestStarted: true))
        }
        if Task.isCancelled { throw TransportError.cancelled(requestStarted: true) }
    }
}

/// A network path the debug controls switch.
final class DebugNetworkMonitor: NetworkMonitoring {
    private let state = Mutex<(online: Bool, subscribers: [UUID: AsyncStream<Bool>.Continuation])>((true, [:]))

    func set(online: Bool) {
        let subscribers = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
            state.online = online
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(online) }
    }

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let online = state.withLock { state in
            state.subscribers[id] = continuation
            return state.online
        }
        continuation.yield(online)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}

/// The fake server's topics: Workout (a chip and a number, so the form shows) and Mood (one chip
/// question: the record screen saves on a tap).
enum FakeServer {
    static let workoutId = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
    static let moodId = UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!
    static let epoch = "00000000-0000-4000-8000-0000000000bb"

    static let workoutQuestions = #"""
        [{"help_text": null, "key": "type", "label": "Type", "max_selected": null, "min_selected": null,
          "multiple": false, "required": true, "type": "enum",
          "options": [{"archived": false, "label": "Run", "value": "run"},
                      {"archived": false, "label": "Yoga", "value": "yoga"},
                      {"archived": false, "label": "Swim", "value": "swim"}]},
         {"help_text": null, "key": "duration", "label": "Duration", "max": 600, "min": 1, "required": true,
          "type": "int", "unit": "min"}]
        """#
    static let moodQuestions = #"""
        [{"help_text": null, "key": "mood", "label": "Mood", "max_selected": null, "min_selected": null,
          "multiple": false, "required": true, "type": "enum",
          "options": [{"archived": false, "label": "Good", "value": "good"},
                      {"archived": false, "label": "OK", "value": "ok"},
                      {"archived": false, "label": "Bad", "value": "bad"}]}]
        """#

    static func topic(_ id: UUID, slug: String, name: String, questions: String, count: Int, seq: Int) -> String {
        #"""
        {"kind": "topic", "seq": \#(seq), "topic": {"archived_at": null, "created_at": "2026-01-01T00:00:00Z",
         "current_version": 1, "description": "", "due": null, "entry_count": 0, "id": "\#(id.wireString)",
         "last_captured_at": null, "name": "\#(name)", "question_count": \#(count), "questions": \#(questions),
         "revision": 1, "schedule": null, "schedule_updated_at": null, "slug": "\#(slug)", "status": "active",
         "updated_at": "2026-01-01T00:00:00Z"}}
        """#
    }

    static func version(_ topicId: UUID, versionId: String, questions: String, seq: Int) -> String {
        #"""
        {"id": "\#(versionId)", "kind": "version", "seq": \#(seq), "topic_id": "\#(topicId.wireString)",
         "version": {"change_note": "", "created_at": "2026-01-01T00:00:00Z", "entry_count": 0,
                     "questions": \#(questions), "version": 1}}
        """#
    }

    static func page(after cursor: Int, state: FakeServerState) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let (published, head) = state.feed(after: cursor)
        let seeded =
            cursor == 0
            ? [
                version(
                    workoutId, versionId: "00000000-0000-4000-8000-0000000000d1", questions: workoutQuestions, seq: 1),
                topic(workoutId, slug: "workout", name: "Workout", questions: workoutQuestions, count: 2, seq: 2),
                version(moodId, versionId: "00000000-0000-4000-8000-0000000000d2", questions: moodQuestions, seq: 3),
                topic(moodId, slug: "mood", name: "Mood", questions: moodQuestions, count: 1, seq: 4),
            ] : []
        let items = seeded + published
        return #"""
            {"items": [\#(items.joined(separator: ","))], "deleted": [], "next": \#(head), "has_more": false,
             "head": \#(head),
             "epoch": "\#(epoch)", "server_id": "\#(UITestLaunch.fakeServerId)", "server_time": "\#(now)"}
            """#
    }

    /// The feed's topics as `TopicDetail` objects (the fake server's starting state).
    static func seedTopics() -> [String: Data] {
        var out: [String: Data] = [:]
        for (id, slug, name, questions, count) in [
            (workoutId, "workout", "Workout", workoutQuestions, 2), (moodId, "mood", "Mood", moodQuestions, 1),
        ] {
            let item = topic(id, slug: slug, name: name, questions: questions, count: count, seq: 0)
            guard let object = try? JSONSerialization.jsonObject(with: Data(item.utf8)) as? [String: Any],
                let detail = object["topic"], let data = try? JSONSerialization.data(withJSONObject: detail)
            else { continue }
            out[id.wireString] = data
        }
        return out
    }

    /// A schedule as the server stores and returns it (`dump_schedule`): defaults filled in, times
    /// and days sorted; null stays null.
    static func outputSchedule(_ input: Any) -> Any {
        guard var schedule = input as? [String: Any] else { return NSNull() }
        schedule["notify"] = schedule["notify"] ?? true
        if schedule["kind"] as? String == "daily" {
            schedule["times"] = ((schedule["times"] as? [String]) ?? []).sorted()
            schedule["days"] = ((schedule["days"] as? [Int]) ?? [1, 2, 3, 4, 5, 6, 7]).sorted()
        }
        return schedule
    }

    /// Questions (input or output JSON) as the domain's, for the compatibility check.
    static func questions(_ json: Any) -> [Question] {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
            let dtos = try? WireCoding.decoder().decode([QuestionInputDTO].self, from: data)
        else { return [] }
        return dtos.map { $0.toDomain() }
    }

    /// A created question as the server returns it: the input with its defaults filled in.
    static func outputQuestion(_ input: [String: Any]) -> [String: Any] {
        var q = input
        q["help_text"] = q["help_text"] ?? NSNull()
        q["required"] = q["required"] ?? true
        switch q["type"] as? String {
        case "str":
            q["min_length"] = q["min_length"] ?? 0
            q["max_length"] = q["max_length"] ?? 500
            q["multiline"] = q["multiline"] ?? false
        case "enum":
            q["multiple"] = q["multiple"] ?? false
            q["min_selected"] = q["min_selected"] ?? NSNull()
            q["max_selected"] = q["max_selected"] ?? NSNull()
            q["options"] = ((q["options"] as? [[String: Any]]) ?? []).map { option in
                var o = option
                o["archived"] = o["archived"] ?? false
                return o
            }
        default:
            for key in ["min", "max", "unit"] { q[key] = q[key] ?? NSNull() }
            if q["type"] as? String == "double" { q["decimals"] = q["decimals"] ?? NSNull() }
        }
        return q
    }

    /// The answers of a create, as the server echoes them (`[{key, type, value}]`).
    static func echo(_ answers: [String: Any]) -> [[String: Any]] {
        answers.sorted { $0.key < $1.key }.map { key, value in
            let type = value is Int ? "int" : value is Double ? "double" : value is [String] ? "enum_list" : "enum"
            return ["key": key, "type": type, "value": value]
        }
    }
}

/// `https://quickr.test`: the feed above, entry creates (201, or 422 for a duration over 600 or
/// when `state` is told to reject the next, so a rejection can be shown), deletes (204, for
/// Undo after a send), stats and series (`FakeStats`), TOPIC's topic writes (`topicRoute`), and
/// BUILDER-UI's topic reads and versions (`topicDetail`, `versionRoute`).
/// Offline (`state`), every request there fails before it is sent; held feed
/// requests wait. Any other host goes to `fallback`.
private struct FakeServerTransport: Transport {
    let fallback: any Transport
    let state: FakeServerState

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.host() == UITestLaunch.fakeServer.host() else { return try await fallback.send(request) }
        state.counted()
        if state.offline { throw TransportError.unreachable("offline (UI test)") }
        let headers: HTTPHeaders = [
            QuickrHeader.serverId: UITestLaunch.fakeServerId, QuickrHeader.epoch: FakeServer.epoch,
            "Content-Type": "application/json",
        ]
        let path = request.url.path()
        if request.method == .get, path == "/api/v1/changes" {
            try await state.waitIfFeedHeld()
            let after =
                URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "after" }?.value.flatMap(Int.init) ?? 0
            return HTTPResponse(
                status: 200, headers: headers, body: Data(FakeServer.page(after: after, state: state).utf8))
        }
        if request.method == .post, path.hasPrefix("/api/v1/topics/"), path.hasSuffix("/entries") {
            return create(request, headers: headers)
        }
        if request.method == .delete, path.hasPrefix("/api/v1/entries/") {
            return HTTPResponse(status: 204, headers: headers)
        }
        if request.method == .get, path.hasPrefix("/api/v1/topics/"), path.hasSuffix("/entries.csv") {
            var csv = headers
            csv["Content-Type"] = "text/csv; charset=utf-8"
            return HTTPResponse(status: 200, headers: csv, body: Data("id,captured_at\n".utf8))
        }
        if request.method == .get, let topic = topicDetail(path: path) {
            return HTTPResponse(status: 200, headers: headers, body: topic)
        }
        if request.method == .get, let body = stats(request, path: path) {
            return HTTPResponse(status: 200, headers: headers, body: body)
        }
        if request.method != .get, path == "/api/v1/topics" || path.hasPrefix("/api/v1/topics/") {
            if let response = topicRoute(request, path: path, headers: headers) { return response }
        }
        return HTTPResponse(
            status: 404, headers: headers, body: Data(#"{"code":"not_found","detail":"Not found","errors":[]}"#.utf8))
    }

    /// TOPIC's online-only writes and the outbox's archive/unarchive, over `state`'s topics:
    /// `POST /topics` (409 when the slug is taken), `PATCH /topics/{id}`, `POST
    /// /topics/{id}/archive|unarchive`, `DELETE /topics/{id}` (409 unless archived).
    private func topicRoute(_ request: HTTPRequest, path: String, headers: HTTPHeaders) -> HTTPResponse? {
        let parts = path.split(separator: "/").map(String.init)  // api, v1, topics, id?, action?
        func json(_ status: Int, _ object: Any) -> HTTPResponse {
            HTTPResponse(
                status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        func problem(_ status: Int, _ code: String, _ detail: String) -> HTTPResponse {
            json(status, ["code": code, "detail": detail, "errors": [Any]()])
        }
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let now = ISO8601DateFormatter().string(from: Date())
        if parts.count == 3, request.method == .post {
            let name = body["name"] as? String ?? "Topic"
            let slug = body["slug"] as? String ?? name.lowercased().replacingOccurrences(of: " ", with: "-")
            if state.slugTaken(slug, except: nil) { return problem(409, "conflict", "slug '\(slug)' is already taken") }
            let questions = ((body["questions"] as? [[String: Any]]) ?? []).map(FakeServer.outputQuestion)
            let schedule = FakeServer.outputSchedule(body["schedule"] ?? NSNull())
            let topic: [String: Any] = [
                "id": UUID().wireString, "slug": slug, "name": name,
                "description": body["description"] as? String ?? "",
                "status": "active", "current_version": 1, "revision": 1, "question_count": questions.count,
                "entry_count": 0, "last_captured_at": NSNull(), "created_at": now, "updated_at": now,
                "archived_at": NSNull(), "schedule": schedule,
                "schedule_updated_at": schedule is NSNull ? NSNull() : now as Any, "due": NSNull(),
                "questions": questions,
            ]
            state.put(topic)
            return json(201, topic)
        }
        guard parts.count >= 4, var topic = state.topic(parts[3]) else {
            return parts.count >= 4 ? problem(404, "not_found", "topic not found") : nil
        }
        if request.method == .post, parts.count >= 5, parts[4] == "versions" {
            return versionRoute(
                request, id: parts[3], check: parts.count == 6, body: body, json: json, problem: problem)
        }
        let revision = (topic["revision"] as? Int ?? 1) + 1
        switch (request.method, parts.count > 4 ? parts[4] : nil) {
        case (.patch, nil):
            if let slug = body["slug"] as? String, state.slugTaken(slug, except: parts[3]) {
                return problem(409, "conflict", "slug '\(slug)' is already taken")
            }
            for key in ["name", "slug", "description"] where body[key] != nil { topic[key] = body[key] }
            if let input = body["schedule"] {
                // Like the backend: an unchanged schedule keeps its reference point; a removed one
                // clears it.
                let new = FakeServer.outputSchedule(input)
                if !(new as AnyObject).isEqual(topic["schedule"] ?? NSNull()) {
                    topic["schedule"] = new
                    topic["schedule_updated_at"] = new is NSNull ? NSNull() : now as Any
                }
            }
        case (.post, "archive"):
            topic["status"] = "archived"
            topic["archived_at"] = now
        case (.post, "unarchive"):
            topic["status"] = "active"
            topic["archived_at"] = NSNull()
        case (.delete, nil):
            guard topic["status"] as? String == "archived" else {
                return problem(409, "conflict", "archive the topic before deleting it")
            }
            state.removeTopic(parts[3])
            return HTTPResponse(status: 204, headers: headers)
        default:
            return nil
        }
        topic["revision"] = revision
        topic["updated_at"] = now
        state.put(topic)
        return json(200, topic)
    }

    /// `GET /api/v1/topics/{id}`: the topic as the server holds it now.
    private func topicDetail(path: String) -> Data? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == "topics", let topic = state.topic(parts[3]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: topic)
    }

    /// `POST /topics/{id}/versions[/check]` (BUILDER-UI), like the backend: a stale `base_version`
    /// is a 409 `conflict`; the report is the local compatibility check against the current
    /// questions; a publish puts the new version in the feed. With `-QuickrStalePublish`, someone
    /// else publishes (adding "Energy") just before the first one.
    private func versionRoute(
        _ request: HTTPRequest, id: String, check: Bool, body: [String: Any],
        json: (Int, Any) -> HTTPResponse, problem: (Int, String, String) -> HTTPResponse
    ) -> HTTPResponse {
        if state.takePublishElsewhere(), let current = state.topic(id) {
            let energy: [String: Any] = [
                "key": "energy", "label": "Energy", "type": "int", "min": 1, "max": 10, "unit": NSNull(),
                "help_text": NSNull(), "required": false,
            ]
            _ = state.publish(id, questions: (current["questions"] as? [[String: Any]] ?? []) + [energy], note: "")
        }
        guard let topic = state.topic(id) else { return problem(404, "not_found", "topic not found") }
        let current = topic["current_version"] as? Int ?? 1
        if let base = body["base_version"] as? Int, base != current {
            return problem(
                409, "conflict",
                "topic is at version \(current), but this edit was based on version \(base); reload and re-apply your changes"
            )
        }
        let inputs = (body["questions"] as? [[String: Any]]) ?? []
        let report = CompatibilityCheck.report(
            history: [FakeServer.questions(topic["questions"] ?? [Any]())], proposed: FakeServer.questions(inputs))
        if check {
            return json(
                200,
                [
                    "ok": report.ok, "next_version": report.nextVersion,
                    "issues": report.issues.map {
                        ["level": $0.level.rawValue, "question_key": $0.questionKey ?? NSNull(), "message": $0.message]
                            as [String: Any]
                    },
                    "changes": report.changes.map {
                        ["kind": $0.kind.rawValue, "question_key": $0.questionKey, "details": $0.details]
                            as [String: Any]
                    },
                ] as [String: Any])
        }
        guard report.ok else { return problem(422, "incompatible_version", "the new version is incompatible") }
        let note = body["change_note"] as? String ?? ""
        guard let updated = state.publish(id, questions: inputs.map(FakeServer.outputQuestion), note: note) else {
            return problem(404, "not_found", "topic not found")
        }
        return json(201, updated)
    }

    /// `/api/v1/topics/{ref}/stats` and `/api/v1/topics/{ref}/questions/{key}/series` (`FakeStats`).
    private func stats(_ request: HTTPRequest, path: String) -> Data? {
        let parts = path.split(separator: "/").map(String.init)  // api v1 topics {ref} ...
        guard parts.count >= 5, parts[0] == "api", parts[2] == "topics" else { return nil }
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        if parts.count == 5, parts[4] == "stats" { return FakeStats.stats(ref: parts[3], query: query) }
        if parts.count == 7, parts[4] == "questions", parts[6] == "series" {
            return FakeStats.series(ref: parts[3], key: parts[5], query: query)
        }
        return nil
    }

    private func create(_ request: HTTPRequest, headers: HTTPHeaders) -> HTTPResponse {
        guard let data = request.body, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let answers = body["answers"] as? [String: Any]
        else { return HTTPResponse(status: 400, headers: headers) }
        if state.takeReject() {
            return HTTPResponse(
                status: 422, headers: headers,
                body: Data(#"{"code":"invalid_answers","detail":"mood is required","errors":[]}"#.utf8))
        }
        if let duration = answers["duration"] as? Int, duration > 600 {
            let problem = #"""
                {"code": "invalid_answers", "detail": "one or more answers are invalid",
                 "errors": [{"loc": ["answers", "duration"], "message": "must be <= 600"}]}
                """#
            return HTTPResponse(status: 422, headers: headers, body: Data(problem.utf8))
        }
        // The outbox posts by topic id; a slug works too.
        let ref = request.url.pathComponents.dropLast().last ?? ""
        let topicId = ref == "mood" || ref == FakeServer.moodId.wireString ? FakeServer.moodId : FakeServer.workoutId
        let now = ISO8601DateFormatter().string(from: Date())
        let entry: [String: Any] = [
            "id": body["id"] as? String ?? UUID().wireString, "topic_id": topicId.wireString,
            "answers": FakeServer.echo(answers), "captured_at": body["captured_at"] as? String ?? now,
            "channel": "ios", "created_at": now, "updated_at": now, "meta": [String: String](),
            "notes": body["notes"] as? String ?? "", "revision": 1, "source": body["source"] as? String ?? "ios",
            "version": body["version"] as? Int ?? 1,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return HTTPResponse(status: 201, headers: headers, body: json)
    }
}
#endif
