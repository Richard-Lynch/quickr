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
    /// On every request: `ios; level=<APILevel.current>; build=<CFBundleVersion>`
    /// (client-versions.md §3.1).
    public static let client = "X-QuickR-Client"
    /// On every `/api/v1` response: the server's API level (client-versions.md §3.2).
    public static let apiLevel = "X-QuickR-Api-Level"
    /// On every `/api/v1` response: `ios=<int>, web=<int>`, the lowest level the server accepts.
    public static let minClientLevel = "X-QuickR-Min-Client-Level"
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

    /// Sends `request` like ``send(_:)``, but a 2xx response's body goes to the file
    /// `destination` (created; the caller owns it) and the returned body is empty: an export is
    /// never held in memory. Any other status's body (a problem) comes back as usual and nothing
    /// is written. The default writes what ``send(_:)`` returns; the production transport
    /// streams to disk.
    func download(_ request: HTTPRequest, to destination: URL) async throws -> HTTPResponse
}

extension Transport {
    public func download(_ request: HTTPRequest, to destination: URL) async throws -> HTTPResponse {
        var response = try await send(request)
        guard (200..<300).contains(response.status) else { return response }
        do {
            try response.body.write(to: destination)
        } catch {
            throw TransportError.failed("couldn’t write the download: \(error)", requestStarted: true)
        }
        response.body = Data()
        return response
    }
}
