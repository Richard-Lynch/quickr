#if DEBUG
import Foundation
import QuickrData
import Synchronization

/// `-QuickrUITest` (DEBUG only): a clean slate for a UI test, so it never touches the real store,
/// settings or Keychain. A fresh store directory and defaults suite per launch, an in-memory
/// Keychain, and a fake quickR server at `https://quickr.test` (an empty feed); any other host
/// goes to the network, so a test can also onboard against the integration stack.
///
/// With it, `-QuickrServer <url>` presets the server (launch connects, skipping onboarding),
/// `-QuickrOpen <url>` opens a link once the root is up (screenshots, deep-link checks), and
/// `-QuickrSyncControls` shows `UITestSyncControls` (go offline or online, log an entry, reject the
/// next one) for the sync UI tests. The network path is `UITestLaunch.network`, which the
/// controls switch together with the fake server.
enum UITestLaunch {
    static let argument = "-QuickrUITest"
    static let fakeServer = URL(string: "https://quickr.test")!
    static let fakeServerId = "00000000-0000-4000-8000-0000000000aa"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-QuickrSyncControls`, when testing.
    static var showsSyncControls: Bool { isActive && ProcessInfo.processInfo.arguments.contains("-QuickrSyncControls") }

    /// The fake server's switches.
    static let server = FakeServerState()
    /// The network path the app sees while testing.
    static let network = DebugNetworkMonitor()

    @MainActor static func environment() -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-uitest-\(UUID().uuidString)")
        let suite = "quickr.uitest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let environment = AppEnvironment.live(
            location: StoreLocation(root: root), defaults: defaults, keychain: InMemoryKeychain(),
            transport: FakeServerTransport(fallback: URLSessionTransport(), state: server), network: network)
        environment.settings.serverURL = value(after: "-QuickrServer").flatMap(URL.init(string:))
        return environment
    }

    /// `-QuickrOpen <url>`, when testing.
    static var openURL: URL? {
        guard isActive else { return nil }
        return value(after: "-QuickrOpen").flatMap(URL.init(string:))
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

    func releaseFeed() {
        let waiters = state.withLock { state in
            state.holdFeed = false
            defer { state.held = [:] }
            return Array(state.held.values)
        }
        for waiter in waiters { waiter.resume() }
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
            let waiter = state.withLock { state in
                let waiter = state.held.removeValue(forKey: id)
                if waiter != nil { state.cancelled += 1 }
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

/// Answers `https://quickr.test/api/v1/changes` with an empty feed page from a fixed server,
/// accepts entry creates (201, or 422 when told to reject the next), and answers any other path
/// there with a 404; offline, every request there fails before it is sent. Passes every other
/// host to `fallback`.
private struct FakeServerTransport: Transport {
    let fallback: any Transport
    let state: FakeServerState

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.host() == UITestLaunch.fakeServer.host() else { return try await fallback.send(request) }
        state.counted()
        if state.offline { throw TransportError.unreachable("offline (UI test)") }
        if request.url.path() == "/api/v1/changes" { try await state.waitIfFeedHeld() }
        let identity: HTTPHeaders = [
            QuickrHeader.serverId: UITestLaunch.fakeServerId,
            QuickrHeader.epoch: "00000000-0000-4000-8000-0000000000bb",
            "Content-Type": "application/json",
        ]
        if request.method == .post, request.url.path().hasSuffix("/entries") {
            return create(request, identity: identity)
        }
        guard request.url.path() == "/api/v1/changes" else {
            return HTTPResponse(
                status: 404, headers: identity,
                body: Data(#"{"code":"not_found","detail":"Not found","errors":[]}"#.utf8))
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let page = #"""
            {"items": [], "deleted": [], "next": 0, "has_more": false, "head": 0,
             "epoch": "00000000-0000-4000-8000-0000000000bb", "server_id": "\#(UITestLaunch.fakeServerId)",
             "server_time": "\#(now)"}
            """#
        return HTTPResponse(status: 200, headers: identity, body: Data(page.utf8))
    }
}

extension FakeServerTransport {
    /// Echoes the create as an `EntryOut` (revision 1), or rejects it with a Problem.
    fileprivate func create(_ request: HTTPRequest, identity: HTTPHeaders) -> HTTPResponse {
        if state.takeReject() {
            return HTTPResponse(
                status: 422, headers: identity,
                body: Data(#"{"code":"invalid_answers","detail":"mood is required","errors":[]}"#.utf8))
        }
        let body = (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let topicId = request.url.pathComponents.dropFirst(4).first ?? ""
        let answers = (body["answers"] as? [String: Any] ?? [:]).map { key, value in
            ["key": key, "type": value is String ? "str" : "int", "value": value]
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let entry: [String: Any] = [
            "id": body["id"] ?? UUID().uuidString.lowercased(), "topic_id": topicId, "version": body["version"] ?? 1,
            "revision": 1, "source": body["source"] ?? "ios", "channel": "ios",
            "captured_at": body["captured_at"] ?? now, "created_at": now, "updated_at": now,
            "notes": body["notes"] ?? "", "meta": body["meta"] ?? [String: String](), "answers": answers,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return HTTPResponse(status: 201, headers: identity, body: data)
    }
}
#endif
