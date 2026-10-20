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
    @MainActor static func environment(
        categoryCenter: (any NotificationCenterProtocol)? = SystemNotificationCenter()
    ) -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-uitest-\(UUID().uuidString)")
        let suite = "quickr.uitest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let environment = AppEnvironment.live(
            location: StoreLocation(root: root), defaults: defaults, keychain: InMemoryKeychain(),
            transport: FakeServerTransport(fallback: URLSessionTransport(), state: server), network: network,
            categoryCenter: categoryCenter)
        environment.settings.serverURL = value(after: "-QuickrServer").flatMap(URL.init(string:))
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

    static func page(after cursor: Int) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let items =
            cursor == 0
            ? [
                version(
                    workoutId, versionId: "00000000-0000-4000-8000-0000000000d1", questions: workoutQuestions, seq: 1),
                topic(workoutId, slug: "workout", name: "Workout", questions: workoutQuestions, count: 2, seq: 2),
                version(moodId, versionId: "00000000-0000-4000-8000-0000000000d2", questions: moodQuestions, seq: 3),
                topic(moodId, slug: "mood", name: "Mood", questions: moodQuestions, count: 1, seq: 4),
            ] : []
        return #"""
            {"items": [\#(items.joined(separator: ","))], "deleted": [], "next": 4, "has_more": false, "head": 4,
             "epoch": "\#(epoch)", "server_id": "\#(UITestLaunch.fakeServerId)", "server_time": "\#(now)"}
            """#
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
/// when `state` is told to reject the next, so a rejection can be shown) and deletes (204, for
/// Undo after a send). Offline (`state`), every request there fails before it is sent; held feed
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
            return HTTPResponse(status: 200, headers: headers, body: Data(FakeServer.page(after: after).utf8))
        }
        if request.method == .post, path.hasPrefix("/api/v1/topics/"), path.hasSuffix("/entries") {
            return create(request, headers: headers)
        }
        if request.method == .delete, path.hasPrefix("/api/v1/entries/") {
            return HTTPResponse(status: 204, headers: headers)
        }
        return HTTPResponse(
            status: 404, headers: headers, body: Data(#"{"code":"not_found","detail":"Not found","errors":[]}"#.utf8))
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
