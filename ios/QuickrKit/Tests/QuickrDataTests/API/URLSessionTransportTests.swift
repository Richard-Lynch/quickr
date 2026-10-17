import Foundation
import QuickrData
import Synchronization
import Testing

/// `URLSessionTransport` against a real loopback HTTP server.
@Suite struct URLSessionTransportTests {
    static func request(
        _ server: LoopbackServer, _ path: String = "/api/v1/health", method: HTTPMethod = .get,
        headers: HTTPHeaders = [:], body: Data? = nil, timeout: Duration = .seconds(5)
    ) -> HTTPRequest {
        HTTPRequest(
            method: method, url: URL(string: server.baseURL.absoluteString + path)!, headers: headers, body: body,
            timeout: timeout)
    }

    @Test func sendsTheRequestAndReturnsTheResponse() async throws {
        let server = try await LoopbackServer { request in
            .init(
                status: 201, headers: ["X-QuickR-Epoch": "e1", "Content-Type": "application/json"], body: request.body)
        }
        let transport = URLSessionTransport()
        let response = try await transport.send(
            Self.request(
                server, "/api/v1/topics/a%20b/entries", method: .post,
                headers: ["Content-Type": "application/json", QuickrHeader.channel: "ios"], body: Data(#"{"a":1}"#.utf8)
            ))
        #expect(response.status == 201)
        #expect(response.body == Data(#"{"a":1}"#.utf8))
        #expect(response.headers[QuickrHeader.epoch] == "e1", "header names are case-insensitive")
        let seen = try #require(server.requests.first)
        #expect(seen.method == "POST" && seen.target == "/api/v1/topics/a%20b/entries")
        #expect(seen.headers["x-quickr-channel"] == "ios")
    }

    @Test func redirectsAreReturnedNotFollowed() async throws {
        let server = try await LoopbackServer { request in
            request.target == "/login"
                ? .init(status: 200, body: Data("login page".utf8))
                : .init(status: 302, headers: ["Location": "/login"])
        }
        for status in [301, 302, 303, 307, 308] {
            let target = try await LoopbackServer { _ in .init(status: status, headers: ["Location": "/login"]) }
            let response = try await URLSessionTransport().send(
                Self.request(target, method: .post, body: Data("{}".utf8)))
            #expect(response.status == status)
            #expect(target.requests.count == 1, "\(status) was followed")
        }
        let response = try await URLSessionTransport().send(Self.request(server))
        #expect(response.status == 302 && response.headers["Location"] == "/login")
        #expect(server.requests.map(\.target) == ["/api/v1/health"])
    }

    @Test func aSlowServerTimesOut() async throws {
        let server = try await LoopbackServer { _ in nil }  // accepts, never answers
        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut(requestStarted: true)) {
            try await URLSessionTransport().send(Self.request(server, timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aRefusedConnectionIsUnreachable() async throws {
        let transport = URLSessionTransport()
        let request = HTTPRequest(
            method: .post, url: URL(string: "http://127.0.0.1:1/api/v1/health")!, timeout: .seconds(5))
        do {
            _ = try await transport.send(request)
            Issue.record("expected a failure")
        } catch let error as TransportError {
            guard case .unreachable = error else {
                Issue.record("expected unreachable, got \(error)")
                return
            }
            #expect(!error.requestStarted)
        }
    }

    @Test func cancellationBeforeSendingNeverStarts() async throws {
        let server = try await LoopbackServer { _ in .init(status: 200) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await URLSessionTransport().send(Self.request(server))
        }
        await #expect(throws: TransportError.cancelled(requestStarted: false)) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test func gzipBodiesAreDecoded() async throws {
        let json = Data(String(repeating: #"{"status": "ok"}"#, count: 50).utf8)
        let gzipped = try Gzip.compress(json)
        let server = try await LoopbackServer { _ in
            .init(
                status: 200, headers: ["Content-Encoding": "gzip", "Content-Type": "application/json"], body: gzipped)
        }
        let response = try await URLSessionTransport().send(Self.request(server))
        #expect(response.body == json)
        #expect(server.requests.first?.headers["accept-encoding"]?.contains("gzip") == true)
    }

    @Test func cookiesAreNeitherStoredNorSent() async throws {
        let server = try await LoopbackServer { _ in
            .init(status: 200, headers: ["Set-Cookie": "CF_Authorization=abc; Path=/"])
        }
        let transport = URLSessionTransport()
        _ = try await transport.send(Self.request(server))
        _ = try await transport.send(Self.request(server))
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test func responsesAreNeverCached() async throws {
        let counter = Counter()
        let server = try await LoopbackServer { _ in
            .init(status: 200, headers: ["Cache-Control": "max-age=3600"], body: Data("\(counter.next())".utf8))
        }
        let transport = URLSessionTransport()
        let first = try await transport.send(Self.request(server))
        let second = try await transport.send(Self.request(server))
        #expect(first.body != second.body && server.requests.count == 2)
    }

    @Test func theConfigurationIsEphemeralAndCookieless() {
        let configuration = URLSessionTransport.configuration()
        #expect(configuration.httpCookieStorage == nil && configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies && configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.timeoutIntervalForRequest == 15 && !configuration.waitsForConnectivity)
    }

    /// End to end: the client over the real transport classifies a captive portal's HTML 200.
    @Test func clientOverTheRealTransport() async throws {
        let server = try await LoopbackServer { request in
            request.target.hasPrefix("/api/v1/entries")
                ? .init(
                    status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>Wi-Fi login</html>".utf8))
                : .init(status: 302, headers: ["Location": "https://login.example/"])
        }
        let client = APITest.client(URLSessionTransport(), baseURL: server.baseURL)
        let portal = try await client.getEntry(id: UUID())
        #expect(portal.outcome == .identityMismatch(.missingHeaders(status: 200)))
        let bounced = try await client.health()
        #expect(bounced.outcome == .retryable(.redirect(status: 302)))
        #expect(server.requests.count == 2)
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }
}
