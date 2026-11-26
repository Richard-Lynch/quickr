import Foundation
import GRDB
import QuickrCore

/// A topic's latest stop as the idle surfaces offer it "Resume" (active-surfaces.md §2.4, §3.3,
/// §1.2 rows 2 and 13): the latest local entry (the optimistic one of a queued stop included: the
/// run row is gone from the store once acked), whose `timing.terminalId` names the stop a reopen
/// targets (timers2.md §3.3), so no run row or `getRun` is needed, offline included.
public struct ResumableRun: Sendable, Hashable {
    /// The entry's id, which is its run's: `RunActions.reopen(runId:topicId:)` routes it to the run
    /// when it is still in the view, else to the entry (`RunWrites`' reopen from the entry).
    public var runId: String
    public var topicId: UUID
    /// The terminal stop (`entry.timing.terminalId`).
    public var terminalId: UUID
    /// The stop's instant on the run clock (epoch ms, the entry's `captured_at`).
    public var endedAt: Int
    /// The run's active time, for "Resume · 1:44".
    public var totalMs: Int

    public init(runId: String, topicId: UUID, terminalId: UUID, endedAt: Int, totalMs: Int) {
        self.runId = runId
        self.topicId = topicId
        self.terminalId = terminalId
        self.endedAt = endedAt
        self.totalMs = totalMs
    }

    /// Whether it is still offered at `now` (epoch ms on the run clock, the store's server
    /// offset): OQ-1's 15 minutes after the stop (`RunPresentation.reopenWindowMs`), inclusive.
    public func isOffered(at now: Int) -> Bool { now - endedAt <= RunPresentation.reopenWindowMs }

    /// The secondary `reopen(target: terminalId)` of §1.2 rows 2 and 13.
    public var action: RunAction { RunAction(kind: .reopen(target: terminalId), role: .secondary, enabled: true) }

    /// The topic's latest timed entry when the store offers it Resume, the window aside:
    /// `RunOverlay.resumable` (unedited, the topic's latest stop, no locally open run: A15) read at
    /// the stop itself, so only the 15 minutes are left to `isOffered(at:)`, which the surface
    /// reads on its own clock. Nil without a terminal id (a pre-v2 timing: §8.2 shows no Resume).
    public static func latest(_ db: Database, topicId: UUID) throws -> ResumableRun? {
        guard
            let view = try StoreView.entries(db, topicId: topicId.wireString).first(where: { $0.entry.timing != nil }),
            let timing = view.entry.timing, let terminal = timing.terminalId.flatMap(UUID.init(uuidString:))
        else { return nil }
        let runId = view.entry.id.wireString
        guard try RunOverlay.resumable(db, entryId: runId, now: RunInstant.date(timing.endedAt)) else { return nil }
        return ResumableRun(
            runId: runId, topicId: topicId, terminalId: terminal, endedAt: timing.endedAt, totalMs: timing.activeMs)
    }
}

extension LocalStore {
    /// `ResumableRun.latest` for `topicId`, kept current as the store changes (a stop, its ack, a
    /// reopen, an edit of the entry, another run).
    public func observeResumable(topicId: UUID, refresh: AsyncStream<Void>? = nil)
        -> AsyncThrowingStream<ResumableRun?, any Error>
    {
        StoreObservation.values(in: writer, refresh: refresh) { db in try ResumableRun.latest(db, topicId: topicId) }
    }
}
