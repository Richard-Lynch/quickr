import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// M2-RESUME (active-surfaces.md §2.4, §3.3, §1.2 rows 2 and 13): what the idle tile, the idle run
/// screen and the stop toast offer as "Resume": the topic's latest local entry, its
/// `timing.terminalId` the reopen's target, while `RunOverlay.resumable` holds; the 15 minutes are
/// read by the surface on the run clock (`isOffered(at:)`).
extension RunLocalViewTests {
    private static func latest(_ h: OutboxHarness) throws -> ResumableRun? {
        try h.read { db in try ResumableRun.latest(db, topicId: h.topic.id) }
    }

    @Test("Resume: a queued stop's optimistic entry, its terminal the stop, offered for 15 minutes")
    func resumableFromAQueuedStop() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 60)
        _ = try await writes.lap(runId: runId)
        h.wall.advance(by: 44)
        let stop = try Self.appended(try await writes.stop(runId: runId))

        let resumable = try #require(try Self.latest(h), "offline, before the ack")
        #expect(resumable.runId == runId)
        #expect(resumable.topicId == h.topic.id)
        let stopId = try #require(try stop.runEventPayload()).event.id
        #expect(resumable.terminalId == UUID(uuidString: stopId), "the stop this tap made")
        #expect(resumable.totalMs == 104_000)
        #expect(
            resumable.action == RunAction(kind: .reopen(target: resumable.terminalId), role: .secondary, enabled: true))
        #expect(RunHeaderText.reopenTitle(totalMs: resumable.totalMs) == "Resume · 1:44")

        // The window, on the run clock, inclusive.
        let window = RunPresentation.reopenWindowMs
        #expect(resumable.isOffered(at: resumable.endedAt))
        #expect(resumable.isOffered(at: resumable.endedAt + window))
        #expect(!resumable.isOffered(at: resumable.endedAt + window + 1), "gone after 15 minutes")
    }

    @Test("Resume: still offered once the stop is acked (the run row gone), not once reopened")
    func resumableAfterTheAckUntilReopened() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        let (runId, entry) = try await Self.stoppedAndSynced(h)
        let resumable = try #require(try Self.latest(h))
        #expect(resumable.runId == runId)
        #expect(resumable.terminalId.wireString == entry.timing?.terminalId?.lowercased())
        #expect(resumable.endedAt == entry.timing?.endedAt)

        // Reopened here: the run is open again, so nothing is offered (A15).
        _ = try await h.runs().reopen(runId: runId)
        #expect(try Self.latest(h) == nil)
    }

    @Test("Resume: none while the topic has an open run, none for an untimed entry, the latest stop only")
    func resumableOnlyTheLatestStop() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        #expect(try Self.latest(h) == nil, "no entry yet")
        let (first, _) = try await Self.stoppedAndSynced(h, laps: [], stop: 30)
        h.wall.advance(by: 10)
        let (second, _) = try await Self.stoppedAndSynced(h, laps: [], stop: 30)
        #expect(try Self.latest(h)?.runId == second)
        #expect(first != second)

        h.wall.advance(by: 10)
        let open = try await h.start()
        #expect(try Self.latest(h) == nil, "another run is open: a reopen would be refused")
        _ = try await h.runs().discard(runId: open)
        #expect(try Self.latest(h)?.runId == second)

        _ = try h.seedEntry()
        #expect(try Self.latest(h)?.runId == second, "an untimed entry isn't a stop")
    }

    @Test("Resume: observeResumable follows the store")
    func observeResumableFollowsTheStore() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        var values = h.store.observeResumable(topicId: h.topic.id).makeAsyncIterator()
        #expect(try await values.next() == .some(nil))
        let (runId, _) = try await Self.stoppedAndSynced(h, laps: [], stop: 30)
        var seen: ResumableRun?
        while let value = try await values.next() {
            seen = value
            if value != nil { break }
        }
        #expect(seen?.runId == runId)
    }
}
