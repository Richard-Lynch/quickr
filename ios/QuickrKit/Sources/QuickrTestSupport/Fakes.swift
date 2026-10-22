import Foundation
import QuickrData
import Synchronization

/// A scripted `Transport`. Each request is answered by the first matching stub (stubs stay until
/// removed), else by the next queued result, else it fails with `.unreachable`. Every request is
/// recorded.
public final class FakeTransport: Transport {
    public typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private struct State {
        var stubs: [(matches: @Sendable (HTTPRequest) -> Bool, handler: Handler)] = []
        var queue: [Result<HTTPResponse, TransportError>] = []
        var requests: [HTTPRequest] = []
    }

    private let state = Mutex(State())
    /// Runs at the start of every asynchronous query (`notificationCategories`,
    /// `deliveredNotifications`, `pendingNotificationRequests`), with its name: tests assert
    /// there that no transaction is open (notifications.md N6).
    private let onQuery: (@Sendable (String) -> Void)?

    public init(onQuery: (@Sendable (String) -> Void)? = nil) {
        self.onQuery = onQuery
    }

    /// Answers every request for which `matches` is true.
    public func stub(where matches: @escaping @Sendable (HTTPRequest) -> Bool, _ handler: @escaping Handler) {
        state.withLock { $0.stubs.append((matches, handler)) }
    }

    /// Answers `method path` (path without query) with `response`.
    public func stub(_ method: HTTPMethod, _ path: String, _ response: HTTPResponse) {
        stub(where: { $0.method == method && $0.url.path == path }, { _ in response })
    }

    /// Answers the next unmatched request.
    public func enqueue(_ result: Result<HTTPResponse, TransportError>) {
        state.withLock { $0.queue.append(result) }
    }

    public var requests: [HTTPRequest] { state.withLock { $0.requests } }

    public func reset() { state.withLock { $0 = State() } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let next: Result<HTTPResponse, TransportError>? = try state.withLock { state in
            state.requests.append(request)
            if let stub = state.stubs.first(where: { $0.matches(request) }) {
                return .success(try stub.handler(request))
            }
            return state.queue.isEmpty ? nil : state.queue.removeFirst()
        }
        guard let next else { throw TransportError.unreachable("FakeTransport: no stub for \(request.url)") }
        return try next.get()
    }
}

/// A settable wall clock.
public final class FakeClock: WallClock {
    private let current: Mutex<Date>

    public init(_ now: Date = Date(timeIntervalSince1970: 1_772_625_600)) {  // 2026-03-04T12:00:00Z
        current = Mutex(now)
    }

    public func now() -> Date { current.withLock { $0 } }

    public func set(_ date: Date) { current.withLock { $0 = date } }

    public func advance(by seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

/// A settable lease clock. `reboot()` starts a new boot session, which expires every deadline.
public final class FakeLeaseClock: LeaseClock {
    private let current: Mutex<LeaseInstant>

    public init(bootId: String = "boot-1", ct: Int64 = 1_000_000_000) {
        current = Mutex(LeaseInstant(bootId: bootId, ct: ct))
    }

    public func now() -> LeaseInstant { current.withLock { $0 } }

    public func advance(by duration: Duration) { current.withLock { $0 = $0.adding(duration) } }

    public func reboot(bootId: String = UUID().uuidString, ct: Int64 = 1_000_000_000) {
        current.withLock { $0 = LeaseInstant(bootId: bootId, ct: ct) }
    }
}

/// An in-memory notification center that records every call.
public final class FakeNotificationCenter: NotificationCenterProtocol {
    public struct State: Sendable {
        public var categories: [NotificationCategorySpec] = []
        /// Every `setNotificationCategories` call, in order.
        public var categoryRegistrations: [[NotificationCategorySpec]] = []
        /// The system's limit on registered categories (checkpoint D: 100 on the simulator). Over
        /// it, the fake keeps an arbitrary subset (the first by id), as the system doesn't say which.
        public var categoryCapacity: Int?
        public var delivered: [NotificationSnapshot] = []
        public var pending: [NotificationSnapshot] = []
        public var added: [LocalNotificationRequest] = []
        public var badge: Int = 0
        public var authorization: NotificationAuthorization = .authorized
        public var grantsAuthorization = true
    }

    private let state = Mutex(State())
    /// Runs at the start of every asynchronous query (`notificationCategories`,
    /// `deliveredNotifications`, `pendingNotificationRequests`), with its name: tests assert
    /// there that no transaction is open (notifications.md N6).
    private let onQuery: (@Sendable (String) -> Void)?

    public init(onQuery: (@Sendable (String) -> Void)? = nil) {
        self.onQuery = onQuery
    }

    /// Reads or changes the recorded state.
    public func withState<T>(_ body: (inout State) -> T) -> T { state.withLock { body(&$0) } }

    public func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        state.withLock {
            let kept = $0.categoryCapacity.map { Array(categories.sorted { $0.id < $1.id }.prefix($0)) }
            $0.categories = kept ?? categories
            $0.categoryRegistrations.append(categories)
        }
    }

    public func notificationCategories() async -> [NotificationCategorySpec] {
        onQuery?("notificationCategories")
        return state.withLock { $0.categories }
    }

    public func deliveredNotifications() async -> [NotificationSnapshot] {
        onQuery?("deliveredNotifications")
        return state.withLock { $0.delivered }
    }

    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        state.withLock { $0.delivered.removeAll { identifiers.contains($0.id) } }
    }

    public func pendingNotificationRequests() async -> [NotificationSnapshot] {
        onQuery?("pendingNotificationRequests")
        return state.withLock { $0.pending }
    }

    public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        state.withLock { $0.pending.removeAll { identifiers.contains($0.id) } }
    }

    public func add(_ request: LocalNotificationRequest) async throws {
        state.withLock {
            $0.added.append(request)
            $0.pending.removeAll { $0.id == request.id }
            $0.pending.append(
                NotificationSnapshot(
                    id: request.id, categoryIdentifier: request.categoryIdentifier ?? "",
                    threadIdentifier: request.threadIdentifier ?? "", date: request.fireDate, quickr: request.quickr))
        }
    }

    public func setBadgeCount(_ count: Int) async throws { state.withLock { $0.badge = count } }

    public func authorizationStatus() async -> NotificationAuthorization { state.withLock { $0.authorization } }

    public func requestAuthorization() async throws -> Bool {
        state.withLock {
            if $0.authorization == .notDetermined { $0.authorization = $0.grantsAuthorization ? .authorized : .denied }
            return $0.authorization.allowsDelivery
        }
    }
}

/// A network path the test switches: every `updates()` stream gets the current state first,
/// then each `set(online:)`.
public final class FakeNetworkMonitor: NetworkMonitoring {
    private let state: Mutex<(online: Bool, subscribers: [UUID: AsyncStream<Bool>.Continuation])>

    public init(online: Bool = true) { state = Mutex((online, [:])) }

    public var online: Bool { state.withLock { $0.online } }

    public func set(online: Bool) {
        let subscribers = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
            state.online = online
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(online) }
    }

    public func updates() -> AsyncStream<Bool> {
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

/// A `FlushTimerSleeper` the test drives: each sleep is recorded and waits until `wake()` (or is
/// cancelled).
public final class ManualSleeper: FlushTimerSleeper {
    private struct State {
        var requested: [Duration] = []
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Every duration asked for, in order.
    public var requested: [Duration] { state.withLock { $0.requested } }

    /// Sleeps waiting to be woken.
    public var pending: Int { state.withLock { $0.waiters.count } }

    public func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state -> Bool in
                    state.requested.append(duration)
                    if state.cancelled.remove(id) != nil { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                guard let waiter = state.waiters.removeValue(forKey: id) else {
                    state.cancelled.insert(id)  // cancelled before it registered
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Ends every pending sleep normally.
    public func wake() {
        let waiters = state.withLock { state in
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}
