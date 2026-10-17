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

    public init() {}

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
        public var delivered: [NotificationSnapshot] = []
        public var pending: [NotificationSnapshot] = []
        public var added: [LocalNotificationRequest] = []
        public var badge: Int = 0
        public var authorization: NotificationAuthorization = .authorized
        public var grantsAuthorization = true
    }

    private let state = Mutex(State())

    public init() {}

    /// Reads or changes the recorded state.
    public func withState<T>(_ body: (inout State) -> T) -> T { state.withLock { body(&$0) } }

    public func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        state.withLock {
            $0.categories = categories
            $0.categoryRegistrations.append(categories)
        }
    }

    public func notificationCategories() async -> [NotificationCategorySpec] { state.withLock { $0.categories } }

    public func deliveredNotifications() async -> [NotificationSnapshot] { state.withLock { $0.delivered } }

    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        state.withLock { $0.delivered.removeAll { identifiers.contains($0.id) } }
    }

    public func pendingNotificationRequests() async -> [NotificationSnapshot] { state.withLock { $0.pending } }

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
