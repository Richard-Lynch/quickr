import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The run intents' outcomes (timers.md §11.1, §11.3): a timed widget's buttons, the Timer
/// Control, the Action button and Siri all go through `RunWrites.perform`, which decides and
/// writes in one transaction and says what it did.
@Suite struct RunIntentTests {
    static func auto(_ topicId: UUID?, origin: OutboxOrigin = .siri) -> RunIntentRequest {
        RunIntentRequest(action: .auto, topicId: topicId, origin: origin)
    }

    /// A second timed topic, "Dishwasher", with one step.
    static func dishwasher(_ h: OutboxHarness) throws -> Topic {
        let topic = Make.topic(name: "Dishwasher")
        let version = TopicVersion(
            version: 1, questions: [], timer: TopicTimer(steps: [TopicTimer.Step(key: "wash", label: "Wash")]),
            createdAt: Make.t0)
        try h.write { db in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topic.id)
        }
        return topic
    }

    // MARK: - Idle

    @Test func autoOnAnIdleTopicStartsItAndNamesTheFirstStep() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let result = try await h.runs(.siri).perform(Self.auto(h.topic.id))
        let expected1: RunIntentOutcome = .started(topic: "Mood", first: "Shower", waitingDetails: false)
        #expect(result.outcome == expected1)
        #expect(result.wrote)
        #expect(result.started)
        #expect(result.topicId == h.topic.id)
        #expect(result.outcome.spokenText == "Started Mood. First: Shower.")
        let item = try #require(try h.runItems.first)
        #expect(item.origin == .siri)
        let type = try h.payload(item).event.type
        #expect(type == "start")
    }

    @Test func anUntimedTopicIsNotStarted() async throws {
        let h = try OutboxHarness()
        let result = try await h.runs(.siri).perform(Self.auto(h.topic.id))
        let expected2: RunIntentOutcome = .notTimed(topic: "Mood")
        #expect(result.outcome == expected2)
        #expect(!result.wrote)
        #expect(try h.runItems.isEmpty)
    }

    @Test func stopOnAnIdleTopicWritesNothing() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let result = try await h.runs(.siri).perform(
            RunIntentRequest(action: .stop, topicId: h.topic.id, origin: .siri))
        let expected3: RunIntentOutcome = .notRunning(topic: "Mood", finishing: false)
        #expect(result.outcome == expected3)
        #expect(try h.runItems.isEmpty)
    }

    // MARK: - Running

    @Test func autoOnARunningTopicGoesToTheNextStepAndSaysHowLongTheLastTook() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        h.wall.advance(by: 252.4)
        let result = try await writes.perform(Self.auto(h.topic.id))
        let expected4: RunIntentOutcome = .advanced(done: "Shower", ms: 252_400, next: "Breakfast")
        #expect(result.outcome == expected4)
        #expect(result.outcome.shownText == "Shower took 4:12. Next: Breakfast.")
        #expect(result.outcome.spokenText == "Shower took 4 minutes 12 seconds. Next: Breakfast.")
        #expect(!result.started, "only a start requests the Live Activity")
    }

    @Test func startOnARunningTopicRoutesToItsRun() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        let again = try await writes.perform(RunIntentRequest(action: .start, topicId: h.topic.id, origin: .siri))
        let expected5: RunIntentOutcome = .alreadyRunning(topic: "Mood")
        #expect(again.outcome == expected5)
        #expect(!again.wrote)
        #expect(try h.runItems.count == 1)
    }

    @Test func pauseAndResumeSayWhenTheyHadNothingToDo() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        func act(_ action: RunIntentAction) async throws -> RunIntentOutcome {
            try await writes.perform(RunIntentRequest(action: action, topicId: h.topic.id, origin: .siri)).outcome
        }
        let got6: RunIntentOutcome = try await act(.pause)
        let expected6: RunIntentOutcome = .paused(topic: "Mood")
        #expect(got6 == expected6)
        let got7: RunIntentOutcome = try await act(.pause)
        let expected7: RunIntentOutcome = .alreadyPaused(topic: "Mood")
        #expect(got7 == expected7)
        let got8: RunIntentOutcome = try await act(.resume)
        let expected8: RunIntentOutcome = .resumed(topic: "Mood")
        #expect(got8 == expected8)
        let got9: RunIntentOutcome = try await act(.resume)
        let expected9: RunIntentOutcome = .notPaused(topic: "Mood")
        #expect(got9 == expected9)
        let types = try h.runItems.map { try h.payload($0).event.type }
        #expect(types == ["start", "pause", "resume"])
    }

    /// The pinned version's steps aren't stored here (this device started a version it hasn't
    /// synced yet): the local fold has no steps, so no named step "remains", yet one may. Auto is
    /// a plain Next then, never a Stop.
    @Test func autoWithUnknownStepsIsNextNotStop() async throws {
        let h = try OutboxHarness()
        try h.timed()
        _ = try await h.runs(.siri).start(topic: h.ref, version: 9)
        let result = try await h.runs(.siri).perform(Self.auto(h.topic.id))
        guard case .advanced(_, _, let next) = result.outcome else {
            Issue.record("not advanced: \(result.outcome)")
            return
        }
        #expect(next == nil, "which step opened isn't known here")
        let type = try h.payload(try #require(try h.runItems.last)).event.type
        #expect(type == "next")
    }

    // MARK: - Last step

    @Test func autoOnTheLastStepStopsAndSaves() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)))
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        h.wall.advance(by: 462)
        let result = try await writes.perform(Self.auto(h.topic.id))
        let expected10: RunIntentOutcome = .saved(topic: "Mood", ms: 462_000)
        #expect(result.outcome == expected10)
        #expect(result.outcome.shownText == "Saved Mood: 7:42.")
        #expect(result.outcome.spokenText == "Saved Mood: 7 minutes 42 seconds.")
    }

    @Test func aStopThatLeavesTheRunFinishingSaysToAddDetails() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)), requiresAnswers: true)
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        h.wall.advance(by: 462)
        let result = try await writes.perform(RunIntentRequest(action: .stop, topicId: h.topic.id, origin: .siri))
        let expected11: RunIntentOutcome = .savedNeedsDetails(topic: "Mood", ms: 462_000)
        #expect(result.outcome == expected11)
        #expect(result.outcome.shownText == "Saved 7:42. Open quickR to add details.")
    }

    // MARK: - Finishing

    /// I-OUTBOX L5: a finishing run isn't open, so Auto starts a new run (the finishing one keeps
    /// waiting for its answers), and says so; a stop has nothing to stop.
    @Test func autoOnAFinishingTopicStartsANewRun() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)), requiresAnswers: true)
        let writes = h.runs(.siri)
        let first = try await writes.perform(Self.auto(h.topic.id))
        _ = try await writes.perform(Self.auto(h.topic.id))
        let stop = try await writes.perform(RunIntentRequest(action: .stop, topicId: h.topic.id, origin: .siri))
        let expected12: RunIntentOutcome = .notRunning(topic: "Mood", finishing: true)
        #expect(stop.outcome == expected12)
        #expect(stop.outcome.shownText == "Mood is already stopped. Open quickR to add details.")

        let again = try await writes.perform(Self.auto(h.topic.id))
        let expected13: RunIntentOutcome = .started(topic: "Mood", first: "Shower", waitingDetails: true)
        #expect(again.outcome == expected13)
        #expect(again.started)
        let runs = try h.localRuns()
        let statuses = Set(runs.map(\.status))
        #expect(statuses == [.finishing, .running])
        #expect(first.wrote)
    }

    // MARK: - Several open runs (Siri without a topic)

    @Test func withoutATopicTheOnlyOpenRunIsUsed() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        let result = try await writes.perform(RunIntentRequest(action: .pause, topicId: nil, origin: .siri))
        let expected14: RunIntentOutcome = .paused(topic: "Mood")
        #expect(result.outcome == expected14)
        #expect(result.topicId == h.topic.id)
    }

    @Test func withoutATopicSeveralOpenRunsAreAskedAbout() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let dishwasher = try Self.dishwasher(h)
        let writes = h.runs(.siri)
        _ = try await writes.perform(Self.auto(h.topic.id))
        _ = try await writes.perform(Self.auto(dishwasher.id))
        let before = try h.runItems.count
        let result = try await writes.perform(RunIntentRequest(action: .stop, topicId: nil, origin: .siri))
        guard case .chooseTopic(let refs) = result.outcome else {
            Issue.record("not asked: \(result.outcome)")
            return
        }
        #expect(refs.map(\.name) == ["Dishwasher", "Mood"])
        #expect(!result.wrote)
        #expect(try h.runItems.count == before)
    }

    @Test func withoutATopicOrAnOpenRunAStartAsksAndAStopSaysNothingIsRunning() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.siri)
        let start = try await writes.perform(RunIntentRequest(action: .start, topicId: nil, origin: .siri))
        let expected15: RunIntentOutcome = .chooseTopic([])
        #expect(start.outcome == expected15)
        let stop = try await writes.perform(RunIntentRequest(action: .stop, topicId: nil, origin: .siri))
        let expected16: RunIntentOutcome = .nothingRunning
        #expect(stop.outcome == expected16)
        #expect(try h.runItems.isEmpty)
    }

    // MARK: - A widget's own content (`.shown`)

    /// A widget's Next carries the segment it showed: drawn before a Next from elsewhere, its tap
    /// is queued as shown and voided (stale), so it never skips a step the user didn't see.
    @Test func aWidgetTapOnASegmentThatMovedOnDoesNothing() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.widget)
        let started = try await writes.perform(Self.auto(h.topic.id, origin: .widget))
        let runId = try #require(try h.localRuns().first?.id)
        let shown = RunIntentRequest.Shown(runId: runId, seg: 0)
        let next = RunIntentRequest(action: .next, topicId: h.topic.id, origin: .widget, shown: shown)
        h.wall.advance(by: 5)
        let first = try await writes.perform(next)
        let expected17: RunIntentOutcome = .advanced(done: "Shower", ms: 5_000, next: "Breakfast")
        #expect(first.outcome == expected17)
        let second = try await writes.perform(next)
        let expected18: RunIntentOutcome = .moved(topic: "Mood")
        #expect(second.outcome == expected18)
        let run = try #require(try h.localRun(runId))
        let open: String? = run.state.open?.step
        #expect(open == "breakfast", "one step on, not two")
        #expect(started.started)
        let origins = Set(try h.runItems.map(\.origin))
        #expect(origins == [.widget])
    }

    @Test func aWidgetTapOnARunThatStoppedDoesNothing() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.widget)
        _ = try await writes.perform(Self.auto(h.topic.id, origin: .widget))
        let runId = try #require(try h.localRuns().first?.id)
        _ = try await writes.perform(RunIntentRequest(action: .stop, topicId: h.topic.id, origin: .widget))
        let before = try h.runItems.count
        let stale = RunIntentRequest(
            action: .stop, topicId: h.topic.id, origin: .widget, shown: .init(runId: runId, seg: 0))
        let result = try await writes.perform(stale)
        let expected19: RunIntentOutcome = .notRunning(topic: "Mood", finishing: false)
        #expect(result.outcome == expected19)
        #expect(try h.runItems.count == before)
    }

    // MARK: - Siri's actions and spoken durations

    @Test func siriNextIsAuto() {
        #expect(RunActionKind.next.action == .auto)
        #expect(RunActionKind.auto.action == .auto)
        #expect(RunActionKind.start.action == .start)
        #expect(RunActionKind.stop.action == .stop)
    }

    @Test func durationsAreSpokenNaturally() {
        let outcome = RunIntentOutcome.lapped(done: "Lap 1", ms: 3_725_999)
        #expect(outcome.shownText == "Lap 1 took 1:02:05.")
        #expect(outcome.spokenText == "Lap 1 took 1 hour 2 minutes 5 seconds.")
        let short = RunIntentOutcome.saved(topic: "Tea", ms: 60_000)
        #expect(short.spokenText == "Saved Tea: 1 minute.")
    }

    @Test func aLockedPhoneGetsTheFriendlyMessage() {
        let message = RunIntents.message(for: RunActivityTaps.Failure.locked)
        #expect(message == "Unlock your iPhone to use quickR’s buttons.")
        #expect(RunIntents.message(for: CancellationError()) == nil)
    }
}
