import Foundation

/// The quickR request and response headers (sync-protocol.md §1.4, outbox.md §4).
public enum QuickrHeader {
    public static let channel = "X-QuickR-Channel"
    /// On every `/api/v1` response (F9).
    public static let serverId = "X-QuickR-Server-Id"
    /// On every `/api/v1` response (F9).
    public static let epoch = "X-QuickR-Epoch"
    /// On every mutation the iOS client sends (F10).
    public static let expectServerId = "X-QuickR-Expect-Server-Id"
    /// On every mutation the iOS client sends (F10).
    public static let expectEpoch = "X-QuickR-Expect-Epoch"
    public static let cfAccessClientId = "CF-Access-Client-Id"
    public static let cfAccessClientSecret = "CF-Access-Client-Secret"
}

/// HTTP header fields with case-insensitive names.
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    private var fields: [String: String] = [:]

    public init(_ fields: [String: String] = [:]) {
        for (name, value) in fields { self[name] = value }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        for (name, value) in elements { self[name] = value }
    }

    public subscript(name: String) -> String? {
        get { fields[name.lowercased()] }
        set { fields[name.lowercased()] = newValue }
    }

    /// Every field, with lowercased names.
    public var all: [String: String] { fields }
}

public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Data?
    /// 30 s for feed pages, 15 s for outbox sends (sync-protocol.md §1.1, outbox.md §4).
    public var timeout: Duration

    public init(method: HTTPMethod, url: URL, headers: HTTPHeaders = [:], body: Data? = nil, timeout: Duration) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: Int, headers: HTTPHeaders = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Why no response arrived. `requestStarted` feeds `maybe_delivered` (outbox.md §5.1).
public enum TransportError: Error, Sendable, Hashable {
    /// No network path, DNS or TLS failure before anything was sent.
    case unreachable(String)
    case timedOut(requestStarted: Bool)
    case cancelled(requestStarted: Bool)
    case failed(String, requestStarted: Bool)

    public var requestStarted: Bool {
        switch self {
        case .unreachable: false
        case .timedOut(let started), .cancelled(let started), .failed(_, let started): started
        }
    }
}

/// Sends one HTTP request. Implementations never follow redirects (a 3xx is returned as is) and
/// throw only `TransportError`. The production one wraps a foreground `URLSession`.
public protocol Transport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
