import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// V6 (client-versions.md §4.1, outbox.md §5.2): a 426 `client_outdated` restores the item's
/// pre-claim state for every kind, sets `client_outdated_min` and refuses later claims; enqueue
/// still works; a build at the server's minimum clears the flag and sends what was kept.
@Suite(.timeLimit(.minutes(5))) struct OutboxClientOutdatedTests {
    static let above = APILevel.current + 1

    static func isEvent(_ request: HTTPRequest) -> Bool { request.url.path.hasSuffix("/events") }

    static func outdatedMin(_ h: OutboxHarness) throws -> Int? {
        try h.read { db in try Int.fetchOne(db, sql: "SELECT client_outdated_min FROM sync_state WHERE id = 1") }
    }

    /// What an update to the level the server demanded does: the stored minimum is this build's
    /// level now, and the first open clears it (`StorePartitions` runs `clearIfMet`).
    static func update(_ h: OutboxHarness) async throws {
        try h.setSyncState("client_outdated_min = \(APILevel.current)")
        await StoreClientLevels(store: h.store).clearIfMet()
        h.server.with { $0.minClientLevelIOS = APILevel.current }
    }

    @Test("V6 · entry.create: a 426 restores it, sets the flag and stops; later claims are refused; an update sends it")
    func entryCreateIsHeldThenSent() async throws {
        let h = try OutboxHarness()
        h.server.with { $0.minClientLevelIOS = Self.above }
        let first = try await h.log(h.outbox())

        let report = try await h.outbox().flushNow()
        #expect(report.ending == .clientOutdated)
        #expect(report.requests == 1)
        #expect(report.settled == 1)
        let held = try #require(try h.item(first))
        #expect(held.state == .pending)
        #expect(held.attempts == 0)
        #expect(held.claimToken == nil)
        #expect(held.preClaimJSON == nil)
        #expect(held.failureReason == nil)
        #expect(!held.maybeDelivered)
        let minimum = try Self.outdatedMin(h)
        #expect(minimum == Self.above)
        #expect(h.server.entry(first) == nil, "refused before any effect")

        // Enqueue still works; nothing is claimed or sent.
        let second = try await h.log(h.outbox(), minutes: 1)
        let again = try await h.outbox().flushNow()
        #expect(again.ending == .clientOutdated)
        #expect(again.requests == 0)
        #expect(h.server.requests.count == 1)
        let states = try h.items.map(\.state)
        #expect(states == [.pending, .pending])

        try await Self.update(h)
        let cleared = try Self.outdatedMin(h)
        #expect(cleared == nil)
        let sent = try await h.outbox().flushNow()
        #expect(sent.acked == 2)
        #expect(h.server.entry(first) != nil)
        #expect(h.server.entry(second) != nil)
    }

    @Test("V6 · an uncertain item keeps maybe_delivered and its state; a held item's attempts aren't counted")
    func uncertainItemIsRestoredAsItWas() async throws {
        let h = try OutboxHarness()
        let id = try await h.log(h.outbox())
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await h.outbox().flushNow()
        let before = try #require(try h.item(id))
        #expect(before.state == .uncertain)

        h.server.with { $0.minClientLevelIOS = Self.above }
        h.server.with { $0.entries = [:] }
        let report = try await h.outbox().flushNow()
        #expect(report.ending == .clientOutdated)
        let after = try #require(try h.item(id))
        #expect(after.state == .uncertain)
        #expect(after.maybeDelivered)
        #expect(after.attempts == before.attempts)
        #expect(after.due == before.due)
    }

    @Test(
        "V6 · run.event: a held start keeps its queued lap waiting, and both replay with the at they were stamped with")
    func runStartWithQueuedLapIsHeldThenReplayed() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 90)
        _ = try await writes.lap(runId: runId)
        let stamped: [Int] = try h.runItems.map { try h.at($0) }
        let tapped: [Int] = [ms(0), ms(90)]
        #expect(stamped == tapped)

        h.server.with { $0.minClientLevelIOS = Self.above }
        let report = try await h.outbox().flushNow()
        #expect(report.ending == .clientOutdated)
        let sent = h.server.requests.filter(Self.isEvent).count
        #expect(sent == 1, "the lap waits behind its held start")
        let held = try h.runItems
        #expect(held.map(\.state) == [.pending, .pending])
        #expect(held.map(\.attempts) == [0, 0])
        #expect(h.server.run(runId) == nil)

        // Later taps are still kept.
        h.wall.advance(by: 30)
        _ = try await writes.stop(runId: runId)
        let refused = try await h.outbox().flushNow()
        #expect(refused.requests == 0)

        h.wall.advance(by: 3_600)
        try await Self.update(h)
        let replay = try await h.outbox().flushNow()
        #expect(replay.acked == 3)
        let events: [HTTPRequest] = Array(h.server.requests.filter(Self.isEvent).dropFirst())
        let ats: [Int] = events.compactMap { (request: HTTPRequest) -> Int? in
            (request.json?["at"] as? String).flatMap(RunInstant.parse)
        }
        let expected: [Int] = [ms(0), ms(90), ms(120)]
        #expect(ats == expected, "each event keeps the at it was stamped with")
        let run = try #require(h.server.run(runId))
        #expect(run.status == .stopped)
    }

    @Test("V6 · with the app's client: the 426's levels set the flag, and later sends are held back before the claim")
    func gatedClientSetsTheFlagAndSendsNothing() async throws {
        let h = try OutboxHarness()
        h.server.with {
            $0.minClientLevelIOS = Self.above
            $0.apiLevel = Self.above
        }
        _ = try await h.log(h.outbox())
        _ = try await h.outbox(levels: true).flushNow()
        let state = try #require(try await h.syncState())
        #expect(state.clientOutdatedMin == Self.above)
        #expect(state.serverApiLevel == Self.above)
        #expect(state.isClientOutdated)
        let gate = await StoreClientLevels(store: h.store).outdatedMinimum()
        #expect(gate == Self.above)
    }

    @Test("V6 · the outbox's own hold sets the flag without the client's record")
    func holdSetsTheFlagInItsTransaction() async throws {
        let h = try OutboxHarness()
        h.server.inject(
            .post,
            .respond(
                header(
                    HTTPResponse(
                        status: 426, headers: ["Content-Type": "application/problem+json"],
                        body: Data(
                            #"{"code":"client_outdated","detail":"Update","errors":[],"min_client_level":7,"client_level":1}"#
                                .utf8)))))
        _ = try await h.log(h.outbox())
        let report = try await h.outbox().flushNow()
        #expect(report.ending == .clientOutdated)
        let minimum = try Self.outdatedMin(h)
        #expect(minimum == max(7, Self.above))
    }

    @Test(
        "V6 · the classification: 426 client_outdated holds every kind",
        arguments: OutboxKind.allCases)
    func everyKindIsHeld(_ kind: OutboxKind) {
        let resolution = OutboxResolution.resolve(kind, .clientOutdated(minimum: 3), runEvent: .start)
        #expect(resolution == .hold(minimum: 3))
        let lap = OutboxResolution.resolve(kind, .clientOutdated(minimum: 3), runEvent: .lap)
        #expect(lap == .hold(minimum: 3))
    }
}
