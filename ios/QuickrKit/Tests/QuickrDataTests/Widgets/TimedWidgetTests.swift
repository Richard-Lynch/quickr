import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// A timed topic's widget (timers.md §11.3), from the store: idle Start; running the open
/// segment, Next (or Lap on the last step) and Stop, and in the small size one Auto button;
/// finishing "Add details". An open run hides the due state and isn't counted as due (§11.1).
@Suite struct TimedWidgetTests {
    static func shown(_ h: OutboxHarness) async throws -> WidgetTopic {
        try #require(try await WidgetReader(store: h.store).topic(id: h.topic.id))
    }

    static func auto(_ h: OutboxHarness) async throws {
        _ = try await h.runs(.widget).perform(RunIntentRequest(action: .auto, topicId: h.topic.id, origin: .widget))
    }

    @Test func anUntimedTopicHasNoRunButtons() async throws {
        let h = try OutboxHarness()
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .untimed)
        #expect(topic.runButtons(compact: false).isEmpty)
    }

    @Test func idleShowsStart() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .idle)
        #expect(topic.run == nil)
        #expect(topic.runButtons(compact: false) == [.start])
        #expect(topic.runButtons(compact: true) == [.start])
        #expect(topic.runURL.absoluteString.hasPrefix("quickr://t/\(h.topic.id.wireString)/run?scope="))
    }

    @Test func runningShowsTheSegmentNextAndStopAndNoDueState() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await Self.auto(h)
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .open(paused: false))
        let label = try #require(topic.runDisplay?.label)
        #expect(label == "Shower")
        #expect(topic.runButtons(compact: false) == [.next, .stop])
        #expect(topic.runButtons(compact: true) == [.next])
        #expect(topic.runButtonLabel(.next) == "Next: Breakfast")
        #expect(topic.hasOpenRun)
        #expect(topic.dueView(at: Make.t0).kind == .none)
        #expect(!topic.countsAsDue(at: Make.t0))
    }

    @Test func theLastStepShowsLapAndStopAndTheSmallSizeStops() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)))
        try await Self.auto(h)
        let topic = try await Self.shown(h)
        #expect(topic.runButtons(compact: false) == [.lap, .stop])
        #expect(topic.runButtons(compact: true) == [.stop])
    }

    /// The pinned version isn't stored: the widget's content says so (`steps_unknown`), and it
    /// offers a plain Next, never Lap or a Stop in Auto's place (and no Skip: widgets have none).
    @Test func unknownStepsShowAPlainNext() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try h.seedServerRun(version: 9)
        let topic = try await Self.shown(h)
        let run = try #require(topic.run)
        let unknown: Bool? = run.stepsUnknown
        #expect(unknown == true)
        #expect(topic.runButtons(compact: false) == [.next, .stop])
        #expect(topic.runButtons(compact: true) == [.next])
        #expect(topic.runButtonLabel(.next) == "Next")
    }

    @Test func finishingOffersAddDetailsWhichOpensTheAnswersForm() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)), requiresAnswers: true)
        try await Self.auto(h)
        try await Self.auto(h)
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .finishing)
        #expect(topic.runButtons(compact: false).isEmpty)
        let runId = try #require(topic.run?.runId)
        #expect(topic.runURL.absoluteString.contains("/record?finish=\(runId)"))
        #expect(!topic.hasOpenRun)
    }

    @Test func aTapChangesTheFingerprintsSoTheAppReloadsTheWidgets() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await Self.auto(h)
        let before = try await Self.shown(h)
        try await Self.auto(h)
        let after = try await Self.shown(h)
        #expect(WidgetFingerprint([before]) != WidgetFingerprint([after]))
        #expect(ControlFingerprint([before]) != ControlFingerprint([after]))
    }
}
