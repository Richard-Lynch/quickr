import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The §11.4 notices (timers.md), kept in the store with their ack (`run_notice`).
@Suite(.timeLimit(.minutes(2))) struct RunNoticeTests {
    /// A run another device stopped `stoppedAt`: its events are on the fake server.
    private func stopElsewhere(_ h: OutboxHarness, _ runId: String) -> Int {
        let stopAt = RunInstant.milliseconds(h.wall.now())
        h.server.with { state in
            var run = state.runs[runId]!
            let stop = RunEvent(id: UUID().wireString, type: .stop, at: stopAt)
            run.append(stop, RunEventInDTO(id: stop.id, type: "stop", at: RunInstant.format(stopAt)))
            run.refold()
            state.runs[runId] = run
        }
        return stopAt
    }

    @Test("§11.4 · an acked void with a noticed reason is kept, with the run's end")
    func anAfterStopVoidIsKept() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        h.wall.advance(by: 10)
        let stoppedAt = stopElsewhere(h, runId)
        h.wall.advance(by: 30)
        let enqueued = try #require(try await writes.next(runId: runId))
        guard case .appended(let next) = enqueued else {
            Issue.record("the Next wasn't appended")
            return
        }
        _ = try await h.outbox().flushNow()

        let notices = try await h.store.runNotices.all()
        let notice = try #require(notices.single)
        let id: String = notice.id
        #expect(id == next.id.lowercased())
        let reason: VoidReason = notice.reason
        #expect(reason == .afterStop)
        let tap: RunEventType = notice.tap
        #expect(tap == .next)
        let stored: Int? = notice.stoppedAt
        #expect(stored == stoppedAt)
        let run: String = notice.runId
        #expect(run == runId)
        let text = notice.text(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasSuffix("so your Next wasn’t added."))
        #expect(text.contains("was already stopped at "))
    }

    @Test("§11.4 · a double tap (stale) is silent: nothing is kept")
    func aStaleVoidIsNotKept() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.next(runId: runId, target: .shown(seg: 0, step: nil, pauseId: nil))
        _ = try await writes.next(runId: runId, target: .shown(seg: 0, step: nil, pauseId: nil))
        let report = try await h.outbox().flushNow()
        let acked: Int = report.acked
        #expect(acked == 3)
        let notices = try await h.store.runNotices.all()
        #expect(notices.isEmpty)
    }

    @Test("§11.4 · dismiss removes a notice; the observation follows")
    func dismissRemovesIt() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        _ = stopElsewhere(h, runId)
        h.wall.advance(by: 5)
        _ = try await writes.lap(runId: runId)
        _ = try await h.outbox().flushNow()
        var updates = h.store.runNotices.observe().makeAsyncIterator()
        let first = try #require(try await updates.next())
        let notice = try #require(first.single)
        try await h.store.runNotices.dismiss(id: notice.id)
        let after = try #require(try await updates.next())
        #expect(after.isEmpty)
    }

    // MARK: Fix of a refused finish

    @Test("§8.1 · a refused finish's draft, and fixRunEvent resends it with new answers")
    func fixRunEventResendsTheFinish() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.stop(runId: runId)
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(9)], notes: "first")
        h.server.inject(
            where: { RunOutboxTests.isEvent($0) && RunOutboxTests.type($0) == "finish" },
            .respond(header(FakeServer.problem(422, "invalid_answers"))))
        _ = try await h.outbox().flushNow()
        let finish = try #require(try h.runItems.last)
        let draft = try #require(finish.runFixDraft(questions: []))
        let type: RunEventType = draft.type
        #expect(type == .finish)
        let answers: [String: AnswerValue] = draft.answers
        #expect(answers == ["mood": .int(9)])
        let notes: String? = draft.notes
        #expect(notes == "first")
        let draftRun: String = draft.runId
        #expect(draftRun == runId)

        try await h.outbox().fixRunEvent(
            itemId: draft.itemId, rowVersion: draft.rowVersion, answers: ["mood": .int(4)], notes: "second")
        // A second fix from the same read loses the compare-and-set.
        await #expect(throws: OutboxError.self) {
            try await h.outbox().fixRunEvent(
                itemId: draft.itemId, rowVersion: draft.rowVersion, answers: ["mood": .int(5)], notes: nil)
        }
        _ = try await h.outbox().flushNow()
        let entry = try #require(h.server.run(runId)?.entry)
        let mood: AnswerValue? = entry.answers["mood"]
        #expect(mood == .int(4))
        let entryNotes: String = entry.notes
        #expect(entryNotes == "second")
    }

    @Test("§8.1 · only a refused finish or stop with answers has a draft")
    func noDraftForOtherEvents() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.next(runId: runId)
        h.server.inject(
            where: { RunOutboxTests.isEvent($0) && RunOutboxTests.type($0) == "next" },
            .respond(header(FakeServer.problem(422, "invalid_request"))))
        _ = try await h.outbox().flushNow()
        let next = try #require(try h.runItems.last)
        let draft = next.runFixDraft(questions: [])
        #expect(draft == nil)
    }
}
