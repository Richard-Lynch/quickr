import Foundation

/// The production `Transport`: a foreground, ephemeral `URLSession` (outbox.md §4).
///
/// - No cookies, no cache, no credential storage: every request stands alone.
/// - **Redirects are never followed**: the delegate refuses them, so a 3xx (an Access proxy
///   bouncing to its login page) comes back as is, like the PWA's `redirect: 'manual'`.
/// - Each request has a hard deadline of `HTTPRequest.timeout` (15 s by default) for the whole
///   exchange, not just between bytes. Expiry is `TransportError.timedOut(requestStarted: true)`.
/// - Compressed responses (`Content-Encoding: gzip`, `deflate`, `br`) are decoded by
///   `URLSession`, which also sends `Accept-Encoding`.
///
/// Only `TransportError` is thrown. Whether a request had started is unknowable for most
/// failures, so anything other than a failure to connect counts as started (the safe side:
/// `maybe_delivered`).
public final class URLSessionTransport: Transport {
    private let session: URLSession
    /// Downloads (exports): the same, but no 60 s cap on the whole transfer; the request's own
    /// deadline bounds it.
    private let downloads: URLSession

    public init(configuration: URLSessionConfiguration = URLSessionTransport.configuration()) {
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
        let downloading = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        downloading.timeoutIntervalForResource = 24 * 3600
        downloads = URLSession(configuration: downloading, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
        downloads.finishTasksAndInvalidate()
    }

    /// Ephemeral, no cookies, no cache, no waiting for connectivity, 15 s timeouts.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = session
        return try await exchange(request) { request in
            let (data, response) = try await session.data(for: request)
            return try Self.response(data, response)
        }
    }

    /// The body arrives in a temporary file, moved to `destination` for a 2xx; any other status's
    /// (small) body is read back into the response.
    public func download(_ request: HTTPRequest, to destination: URL) async throws -> HTTPResponse {
        let downloads = downloads
        return try await exchange(request) { request in
            let (file, response) = try await downloads.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            var http = try Self.response(Data(), response)
            if (200..<300).contains(http.status) {
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                } catch {
                    throw TransportError.failed("couldn’t keep the download: \(error)", requestStarted: true)
                }
            } else {
                http.body = (try? Data(contentsOf: file)) ?? Data()
            }
            return http
        }
    }

    /// One exchange under `request.timeout` as a hard deadline, its errors as `TransportError`s.
    private func exchange(
        _ request: HTTPRequest, _ perform: @escaping @Sendable (URLRequest) async throws -> HTTPResponse
    ) async throws -> HTTPResponse {
        if Task.isCancelled { throw TransportError.cancelled(requestStarted: false) }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.timeoutInterval = request.timeout.timeInterval
        for (name, value) in request.headers.all { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let request = urlRequest
        do {
            return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask { try await perform(request) }
                group.addTask {
                    try await Task.sleep(for: Duration.seconds(request.timeoutInterval))
                    throw TransportError.timedOut(requestStarted: true)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            throw Self.transportError(error)
        } catch is CancellationError {
            throw TransportError.cancelled(requestStarted: true)
        } catch {
            throw TransportError.failed(String(describing: error), requestStarted: true)
        }
    }

    private static func response(_ data: Data, _ response: URLResponse) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.failed("not an HTTP response", requestStarted: true)
        }
        var headers = HTTPHeaders()
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = (value as? String) ?? String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    /// Failures to connect never sent anything; everything else may have.
    static func transportError(_ error: URLError) -> TransportError {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
            .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
            .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL:
            .unreachable("\(error.code.rawValue): \(error.localizedDescription)")
        case .timedOut:
            .timedOut(requestStarted: true)
        case .cancelled:
            .cancelled(requestStarted: true)
        default:
            .failed("\(error.code.rawValue): \(error.localizedDescription)", requestStarted: true)
        }
    }
}

/// Refuses every redirect, so `URLSession` returns the 3xx response itself.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
