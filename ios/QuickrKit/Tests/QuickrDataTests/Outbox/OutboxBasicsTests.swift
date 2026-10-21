import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// outbox.md §13 cases 1–7, 41, 42, 47, 48: persistence, classification, backoff and the flush loop.
@Suite(.timeLimit(.minutes(5))) struct OutboxBasicsTests {
    @Test("1 · an enqueued create is durable, pending, never attempted, keyed by the entry id")
    func case01() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let first = try await h.log(outbox)
        let second = try await h.log(outbox, minutes: 1)
        // A fresh pool (another process, or after a relaunch) reads them.
        let items = try await h.process("widget:1").store.outbox.items()
        #expect(items.map(\.id) == [first.wireString, second.wireString])
        #expect(items.allSatisfy { $0.state == .pending && $0.attempts == 0 && $0.kind == .entryCreate })
        #expect(items[0].seq < items[1].seq)
        #expect(items[0].entityId == first.wireString)
    }

    /// The PWA's `classifyStatus` table (`outbox.test.ts`), through `APIClassifier` and the
    /// outbox's resolution for `entry.create`. `nil` and 0 are "no response".
    @Test(
        "2 · classification matches the PWA's classifyStatus",
        arguments: [
            (200, "ok"), (201, "ok"), (204, "ok"), (nil, "retry"), (0, "retry"), (500, "retry"), (502, "retry"),
            (503, "retry"), (408, "retry"), (429, "retry"), (401, "retry"), (400, "terminal"), (404, "terminal"),
            (409, "terminal"), (422, "terminal"),
        ] as [(Int?, String)])
    func case02(status: Int?, expected: String) throws {
        let identity = ServerIdentity(serverId: "server-1", epoch: "E1")
        let result: Result<HTTPResponse, TransportError>
        switch status {
        case nil, 0: result = .failure(.unreachable("offline"))
        case let status?:
            let body = status < 300 ? Data() : FakeServer.problem(status, "conflict").body
            result = .success(
                HTTPResponse(
                    status: status, headers: [QuickrHeader.serverId: "server-1", QuickrHeader.epoch: "E1"], body: body))
        }
        let response = APIClassifier.classify(result, expected: identity) { _ in OutboxSuccess.empty }
        let resolution = OutboxResolution.resolve(.entryCreate, response.outcome)
        let actual =
            switch resolution {
            case .ack: "ok"
            case .retry: "retry"
            case .fail, .entityGone, .retire: "terminal"
            default: "other"
            }
        #expect(actual == expected)
    }

    @Test("3 · backoff doubles from 2 s, caps at 5 min, jitters ±20 %")
    func case03() {
        #expect(OutboxBackoff.delay(attempts: 1, random: 0.5) == .seconds(2))
        #expect(OutboxBackoff.delay(attempts: 2, random: 0.5) == .seconds(4))
        #expect(OutboxBackoff.delay(attempts: 3, random: 0.5) == .seconds(8))
        #expect(OutboxBackoff.delay(attempts: 30, random: 0.5) == .seconds(300))
        #expect(OutboxBackoff.delay(attempts: 1, random: 0) == .milliseconds(1600))
        #expect(OutboxBackoff.delay(attempts: 1, random: 0.999999) == .milliseconds(2400))
    }

    @Test("4 · a network error stops the pass after the first item")
    func case04() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let first = try await h.log(outbox)
        let second = try await h.log(outbox, minutes: 1)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        let report = try await outbox.flush(force: false, budget: .seconds(120))
        #expect(report.ending == .unreachable)
        #expect(h.server.count(.post) == 1)
        let a = try #require(try h.item(first))
        #expect(a.state == .uncertain && a.maybeDelivered && a.attempts == 1)
        #expect(a.due == h.clock.now().adding(.seconds(2)))
        #expect(try a.errorInfo == OutboxErrorInfo(message: "Could not reach the server"))
        #expect(try h.item(second)?.attempts == 0)
    }

    @Test("5 · a 200 HTML page and a 302 keep the item queued with the PWA messages")
    func case05() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .respond(HTTPResponse(status: 302, headers: ["Location": "/login"])))
        _ = try await outbox.flushNow()
        var item = try #require(try h.item(id))
        #expect(item.state == .pending && !item.maybeDelivered)
        #expect(try item.errorInfo?.message == "The server redirected the request (sign-in required?)")

        let html = Data("<html>captive portal</html>".utf8)
        h.server.inject(
            .post,
            .respond(
                HTTPResponse(
                    status: 200, headers: [QuickrHeader.serverId: "server-1", QuickrHeader.epoch: "E1"], body: html)))
        _ = try await outbox.flushNow()
        item = try #require(try h.item(id))
        #expect(item.state == .uncertain && item.maybeDelivered)
        #expect(try item.errorInfo?.message == "Unexpected response from the server")
        #expect(h.server.entry(id) == nil)
    }

    @Test("6 · a 422 fails the item with the Problem detail; a forced flush doesn't resend it")
    func case06() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .respond(header(FakeServer.problem(422, "invalid_answers", "mood is required"))))
        _ = try await outbox.flush(force: false, budget: .seconds(120))
        let item = try #require(try h.item(id))
        #expect(item.state == .failed && item.failureReason == .rejected)
        #expect(try item.errorInfo?.message == "Mood is required")
        #expect(try item.errorInfo?.status == 422)
        let report = try await outbox.flushNow()
        #expect(report.requests == 0 && h.server.count(.post) == 1)
    }

    @Test("7 · a 503 makes the item uncertain")
    func case07() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .respond(header(FakeServer.problem(503, "internal_error", "down"))))
        _ = try await outbox.flushNow()
        let item = try #require(try h.item(id))
        #expect(item.state == .uncertain && item.maybeDelivered)
    }

    @Test("41 · captured_at 30 h ahead of server time fails future_time without a request; Fix is offered")
    func case41() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox, minutes: 30 * 60)
        _ = try await outbox.flushNow()
        #expect(h.server.requests.isEmpty)
        let item = try #require(try h.item(id))
        #expect(item.state == .failed && item.failureReason == .futureTime && item.attempts == 0)
        // Fix replaces the time and requeues it.
        var body = h.create()
        body.capturedAt = Make.t0
        try await outbox.fix(
            itemId: item.id, payload: .entryCreate(topic: h.ref, body: body), rowVersion: item.rowVersion)
        #expect(try h.item(id)?.state == .pending)
        _ = try await outbox.flushNow()
        #expect(try h.item(id) == nil && h.server.entry(id) != nil)
    }

    @Test("42 · while rebuilding, a widget flush claims nothing; enqueue still works")
    func case42() async throws {
        let h = try OutboxHarness()
        try h.setSyncState("rebuilding = 'E2'")
        let widget = try h.process("widget:1")
        let id = try await h.log(widget)
        // The budget isn't under test: a generous one so a starved CI pool (3 cores, ~1,000
        // parallel tests) can't exhaust it before the rebuilding check runs.
        let report = try await widget.flush(force: true, budget: .seconds(120))
        #expect(report.ending == .paused)
        #expect(try h.server.requests.isEmpty && h.item(id)?.state == .pending)
    }

    @Test("47 · a backoff deadline follows lease time, not the wall clock")
    func case47() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        // Three no-response attempts: the third deadline is +8 s.
        for _ in 0..<3 {
            h.server.inject(.post, .lose(.unreachable("offline")))
            _ = try await outbox.flushNow()
        }
        let item = try #require(try h.item(id))
        #expect(item.attempts == 3 && item.due == h.clock.now().adding(.seconds(8)))
        h.wall.advance(by: -86_400)
        h.clock.advance(by: .seconds(7))
        #expect(try await outbox.flush(force: false, budget: .seconds(120)).requests == 0)
        h.clock.advance(by: .seconds(1))
        _ = try await outbox.flush(force: false, budget: .seconds(120))
        #expect(try h.item(id) == nil && h.server.entry(id) != nil)
    }

    @Test("48 · after a reboot the lease, the backoff deadline and the hold have all passed")
    func case48() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.unreachable("offline")))
        _ = try await outbox.flushNow()
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        // Another process holds the lease when the device reboots.
        _ = try #require(try await h.store.leases.tryAcquire(.flush, owner: "widget:9"))
        h.clock.reboot(bootId: "boot-2", ct: 1)
        let report = try await outbox.flush(force: false, budget: .seconds(120))
        #expect(report.ending == .drained)
        #expect(try h.items.isEmpty)
        #expect(h.server.entry(id) != nil && h.server.entry(entry.id) == nil)
    }
}

/// Adds the server's identity headers to a scripted response.
func header(_ response: HTTPResponse, serverId: String = "server-1", epoch: String = "E1") -> HTTPResponse {
    var response = response
    response.headers[QuickrHeader.serverId] = serverId
    response.headers[QuickrHeader.epoch] = epoch
    return response
}
