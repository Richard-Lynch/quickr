import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// R12 (timers.md §5.1), the store and client half (I-CORE has the pure helpers): the offset comes
/// from the latest response with a round trip ≤ 5 s, errors included, and lives in
/// `sync_state.server_offset_ms`; `at` = device now + offset; a stamp at or before the run's latest
/// `at` is clamped to that `at` + 1 ms; offline stamping uses the last offset.
@Suite(.timeLimit(.minutes(5))) struct RunOffsetTests {
    final class Samples: ServerOffsetRecorder {
        let values = Mutex<[Int]>([])

        func record(offsetMs: Int) async { values.withLock { $0.append(offsetMs) } }

        var all: [Int] { values.withLock { $0 } }
    }

    /// A device clock that reads `ticks` in turn (send, then receive, per request).
    final class Ticks: Sendable {
        let values: Mutex<[Int]>

        init(_ values: [Int]) { self.values = Mutex(values) }

        func next() -> Int { values.withLock { $0.isEmpty ? 0 : $0.removeFirst() } }
    }

    static func client(_ transport: FakeTransport, _ samples: Samples, ticks: Ticks) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://q.example")!, transport: transport,
            identity: StaticServerIdentity(ServerIdentity(serverId: "s", epoch: "e")), serverOffset: samples,
            deviceNow: { ticks.next() })
    }

    static func response(status: Int = 200, serverTime: String?) -> HTTPResponse {
        var headers: HTTPHeaders = [QuickrHeader.serverId: "s", QuickrHeader.epoch: "e"]
        if let serverTime { headers[RunClock.serverTimeHeader] = serverTime }
        return HTTPResponse(status: status, headers: headers, body: Data("{}".utf8))
    }

    @Test("R12 · every response with a round trip ≤ 5 s is a sample, errors included; others are not")
    func samples() async throws {
        let transport = FakeTransport()
        let samples = Samples()
        // (sent, received) per request.
        let ticks = Ticks([1_000, 1_200, 2_000, 7_001, 3_000, 3_100, 4_000, 4_000, 5_000, 5_050])
        let client = Self.client(transport, samples, ticks: ticks)
        transport.enqueue(.success(Self.response(serverTime: "10000")))  // offset 10000 − 1100
        transport.enqueue(.success(Self.response(serverTime: "20000")))  // a 5001 ms round trip
        transport.enqueue(.success(Self.response(serverTime: nil)))  // no header (a proxy)
        transport.enqueue(.success(Self.response(status: 422, serverTime: "9000")))  // an error: 9000 − 4000
        transport.enqueue(.success(Self.response(serverTime: "1.5e3")))  // not an integer
        for _ in 0..<5 { _ = try await client.getRun(id: UUID()) }
        #expect(samples.all == [8_900, 5_000])
    }

    @Test("R12 · the store keeps the latest sample; one beyond 24 h is ignored; a retired store keeps its own")
    func storeOffset() async throws {
        let s = try TestStore()
        let recorder = StoreServerOffset(store: s.store)
        await recorder.record(offsetMs: 2_500)
        await recorder.record(offsetMs: -40)
        await recorder.record(offsetMs: 24 * 3_600_000 + 1)
        let state = try #require(try await s.store.syncState.syncState())
        #expect(state.serverOffsetMs == -40)
        try s.write { db in try db.execute(sql: "UPDATE sync_state SET retired = 1") }
        await recorder.record(offsetMs: 7)
        let retired = try #require(try await s.store.syncState.syncState())
        #expect(retired.serverOffsetMs == -40)
    }

    @Test("R12 · the outbox's sender records its responses' samples in the store")
    func wiredSenders() async throws {
        let h = try OutboxHarness()
        try h.timed()
        h.server.with { $0.serverTime = ms(3) }
        let client = APIClient(
            baseURL: FakeServer.base, transport: h.server, identity: StaticServerIdentity(nil),
            serverOffset: StoreServerOffset(store: h.store), deviceNow: { ms() })
        _ = try await h.start()
        _ = try await Outbox(store: h.store, sender: client, owner: "app:1").flushNow()
        let state = try #require(try await h.syncState())
        #expect(state.serverOffsetMs == 3_000)
    }

    @Test("R12 · at = device now + offset; a device clock that goes back is clamped after the run's latest at")
    func stamping() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try h.setSyncState("server_offset_ms = 2500")
        let device = Mutex(ms())
        let writes = RunWrites(store: h.store, origin: .app, now: { device.withLock { $0 } })
        let runId = try await h.start(writes)
        let start = try #require(try h.item(runId))
        let startAt = try h.at(start)
        #expect(startAt == ms(2.5))

        device.withLock { $0 = ms(-60) }  // the device clock jumps back a minute
        let next = try await writes.next(runId: runId)
        guard case .appended(let nextItem) = next else {
            Issue.record("not appended")
            return
        }
        let nextItemAt = try h.at(nextItem)
        #expect(nextItemAt == ms(2.5) + 1)

        // Offline: no response moves the offset, so taps keep the last one.
        device.withLock { $0 = ms(30) }
        h.server.inject(.post, once: false, .lose(.unreachable("offline")))
        _ = try await h.outbox().flushNow()
        let lap = try await writes.lap(runId: runId)
        guard case .appended(let lapItem) = lap else {
            Issue.record("not appended")
            return
        }
        let lapItemAt = try h.at(lapItem)
        #expect(lapItemAt == ms(32.5))
    }

    @Test("R12 · a failed item's at still counts for the clamp (it may be retried)")
    func failedItemsCount() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let device = Mutex(ms(10))
        let writes = RunWrites(store: h.store, origin: .app, now: { device.withLock { $0 } })
        let run = try h.seedServerRun()
        _ = try await writes.pause(runId: run.id.wireString)
        try h.write { db in
            try db.execute(sql: "UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected'")
        }
        device.withLock { $0 = ms(5) }
        let result = try await writes.lap(runId: run.id.wireString)
        guard case .appended(let item) = result else {
            Issue.record("not appended")
            return
        }
        let itemAt = try h.at(item)
        #expect(itemAt == ms(10) + 1)
    }
}
