import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// The run surfaces' taps (`RunActions`, timers.md §11.1, §11.2): the 450 ms cooldown after any
/// tap on a topic's controls (Start included), the `.expect` target that drops a tap whose control
/// moved, and where Stop leads. Real gaps on a fake clock, across re-renders: each "render" reads
/// the local view again, as the screen does after a write.
@MainActor @Suite(.timeLimit(.minutes(5))) struct RunActionsTests {
    /// A fake monotonic clock for the cooldown.
    final class Clock: Sendable {
        private let offset = Mutex<Duration>(.zero)
        private let base = ContinuousClock.now
        func now() -> ContinuousClock.Instant { base + offset.withLock { $0 } }
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
    }

    private func actions(_ h: OutboxHarness, clock: Clock) -> RunActions {
        let writes = h.runs()
        let writer = RunActions.Writer(
            start: { topic, version in try await writes.start(topic: topic, version: version) },
            tap: { type, runId, target in try await writes.tap(type, runId: runId, target: target) })
        return RunActions(writer: { writer }, now: clock.now)
    }

    /// The run as the screen shows it now.
    private func render(_ h: OutboxHarness, _ runId: String) throws -> LocalRun {
        try #require(try h.localRun(runId))
    }

    private func runTaps(_ h: OutboxHarness) throws -> [String] {
        try h.runItems.map { item in try h.payload(item).event.type }
    }

    @Test("A tap inside the cooldown after Start is ignored: Start turned into Next under the finger")
    func startCoolsDown() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        let run = try render(h, started.runId)
        clock.advance(.milliseconds(200))
        let early: OutboxEnqueueResult? = await actions.tap(.next, run: run, expect: RunTapExpect(run))
        #expect(early == nil)
        clock.advance(.milliseconds(300))
        let later: OutboxEnqueueResult? = await actions.tap(.next, run: run, expect: RunTapExpect(run))
        #expect(later != nil)
        let types = try runTaps(h)
        #expect(types == ["start", "next"])
    }

    @Test("A second Start inside the cooldown is ignored, and one after it routes to the open run")
    func doubleStart() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let first = try #require(await actions.start(topic: h.ref, version: 1))
        let second: RunStartResult? = await actions.start(topic: h.ref, version: 1)
        #expect(second == nil)
        clock.advance(.milliseconds(500))
        let third = try #require(await actions.start(topic: h.ref, version: 1))
        #expect(third.runId == first.runId)
        #expect(third.started == false)
        let count: Int = try h.runItems.count
        #expect(count == 1)
    }

    @Test("Next then Stop within 450 ms, across a re-render: the Stop is never taken from the button that said Next")
    func nextThenStopCoolsDown() async throws {
        let h = try OutboxHarness()
        // Two steps: after one Next the primary button is Stop.
        try h.timed(steps: [TopicTimer.Step(key: "a", label: "A"), TopicTimer.Step(key: "b", label: "B")])
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        clock.advance(.seconds(1))
        let before = try render(h, started.runId)
        let primaryBefore = RunPresentation.primary(before.state, steps: before.steps)
        #expect(primaryBefore == .next(label: "Next: B"))
        let next: OutboxEnqueueResult? = await actions.tap(.next, run: before, expect: RunTapExpect(before))
        #expect(next != nil)

        // Re-rendered: the same button now says Stop. The second tap of the double tap lands 300 ms on.
        let after = try render(h, started.runId)
        let primaryAfter = RunPresentation.primary(after.state, steps: after.steps)
        #expect(primaryAfter == .stop)
        clock.advance(.milliseconds(300))
        let stop: RunActions.StopOutcome? = await actions.stop(
            run: after, topicName: "T", expect: RunTapExpect(after))
        #expect(stop == nil)
        let types = try runTaps(h)
        #expect(types == ["start", "next"])

        // A deliberate Stop, past the cooldown, goes through.
        clock.advance(.milliseconds(200))
        let deliberate: RunActions.StopOutcome? = await actions.stop(
            run: after, topicName: "T", expect: RunTapExpect(after))
        #expect(deliberate != nil)
    }

    @Test("A Next whose control moved (real gap past the cooldown, stale render) enqueues nothing")
    func staleExpectDropsTheTap() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        clock.advance(.seconds(1))
        let shown = try render(h, started.runId)
        let expect = RunTapExpect(shown)
        let first: OutboxEnqueueResult? = await actions.tap(.next, run: shown, expect: expect)
        #expect(first != nil)
        // The screen hasn't caught up: a second tap 600 ms later still carries seg 0.
        clock.advance(.milliseconds(600))
        let second: OutboxEnqueueResult? = await actions.tap(.next, run: shown, expect: expect)
        #expect(second == nil)
        // Re-rendered, the next Next is taken.
        clock.advance(.milliseconds(600))
        let fresh = try render(h, started.runId)
        let third: OutboxEnqueueResult? = await actions.tap(.next, run: fresh, expect: RunTapExpect(fresh))
        #expect(third != nil)
        let open = try #require(try render(h, started.runId).state.open)
        #expect(open.index == 2)
    }

    @Test("Pause twice: the second, past the cooldown, finds the run already paused and enqueues nothing")
    func pauseTwice() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        clock.advance(.seconds(1))
        let shown = try render(h, started.runId)
        let first: OutboxEnqueueResult? = await actions.tap(.pause, run: shown, expect: RunTapExpect(shown))
        #expect(first != nil)
        clock.advance(.seconds(1))
        let second: OutboxEnqueueResult? = await actions.tap(.pause, run: shown, expect: RunTapExpect(shown))
        #expect(second == nil)
    }

    @Test("Stop: a version with questions opens the answers form")
    func stopWithQuestionsOpensTheForm() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        clock.advance(.seconds(1))
        let run = try render(h, started.runId)
        let hasQuestions: Bool? = run.hasQuestions
        #expect(hasQuestions == true)
        let outcome: RunActions.StopOutcome? = await actions.stop(run: run, topicName: "T", expect: RunTapExpect(run))
        #expect(outcome == .details(runId: started.runId))
        let status: RunStatus = try render(h, started.runId).status
        #expect(status == .finishing)
    }

    @Test("Stop: optional questions still open the form (§11.2: the version has questions)")
    func stopWithOptionalQuestionsOpensTheForm() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: false)
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        clock.advance(.seconds(1))
        let run = try render(h, started.runId)
        let outcome: RunActions.StopOutcome? = await actions.stop(run: run, topicName: "T", expect: RunTapExpect(run))
        #expect(outcome == .details(runId: started.runId))
    }

    @Test("Stop: unknown questions (the version isn't stored) open the form")
    func stopWithUnknownQuestionsOpensTheForm() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let clock = Clock()
        let actions = actions(h, clock: clock)
        // Pinned to version 7, which this device doesn't have.
        let started = try #require(await actions.start(topic: h.ref, version: 7))
        clock.advance(.seconds(1))
        let run = try render(h, started.runId)
        let hasQuestions: Bool? = run.hasQuestions
        #expect(hasQuestions == nil)
        let outcome: RunActions.StopOutcome? = await actions.stop(run: run, topicName: "T", expect: RunTapExpect(run))
        #expect(outcome == .details(runId: started.runId))
    }

    @Test("Stop: no questions saves, with the run's active time at the tap")
    func stopWithoutQuestionsSaves() async throws {
        let h = try OutboxHarness()
        try h.timed()
        // Version 2: timed, no questions.
        let row = TopicVersion(
            version: 2, questions: [], timer: TopicTimer(steps: OutboxHarness.steps), createdAt: Make.t0)
        let topicId = h.topic.id
        try h.write { db in _ = try ServerLayer.insert(db, version: row, id: UUID(), topicId: topicId) }
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 2))
        h.wall.advance(by: 125)
        clock.advance(.seconds(1))
        let run = try render(h, started.runId)
        let outcome: RunActions.StopOutcome? = await actions.stop(run: run, topicName: "T", expect: RunTapExpect(run))
        #expect(outcome == .saved(topicName: "T", totalMs: 125_000))
    }

    @Test("Discard follows its confirmation: no cooldown, and a never-sent run leaves no trace (K6)")
    func discard() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let clock = Clock()
        let actions = actions(h, clock: clock)
        let started = try #require(await actions.start(topic: h.ref, version: 1))
        let run = try render(h, started.runId)
        let discarded = await actions.discard(run: run)
        #expect(discarded)
        let count: Int = try h.runItems.count
        #expect(count == 0)
    }
}
