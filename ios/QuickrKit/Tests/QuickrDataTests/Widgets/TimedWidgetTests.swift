import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// A timed topic's widget (timers.md §11.3, active-surfaces.md §5.1), from the store: idle Start;
/// open, the segment, the primary (Next while a step follows, else Lap: §4.1) and Stop, and in the
/// small size the one Auto button of §5.3; finishing "Add details". An open run hides the due state
/// and isn't counted as due (§11.1).
@Suite struct TimedWidgetTests {
    static func shown(_ h: OutboxHarness) async throws -> WidgetTopic {
        try #require(try await WidgetReader(store: h.store).topic(id: h.topic.id))
    }

    static func tap(_ h: OutboxHarness, _ action: RunIntentAction = .auto) async throws {
        _ = try await h.runs(.widget).perform(RunIntentRequest(action: action, topicId: h.topic.id, origin: .widget))
    }

    /// A content state with `label` open: a step (`stepIndex`) with `next` to follow, or a lap.
    static func state(label: String, stepIndex: Int?, next: String?, status: String = "running") -> RunActivityState {
        RunActivityState(
            runId: "00000000-0000-4000-8000-0000000000aa", revision: 1, status: status, startedAt: 0, seg: 2,
            segStartedAt: 0, label: label, stepIndex: stepIndex, stepCount: stepIndex == nil ? 0 : 2, nextLabel: next,
            pausedAt: nil, pausedMsBeforeSeg: 0, pausedMsInSeg: 0, endedAt: nil, activeMs: nil)
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
        #expect(topic.runButtonTitle(.start) == "Start")
        #expect(topic.runButtonLabel(.start) == "Start \(h.topic.name)")
        #expect(topic.runURL.absoluteString.hasPrefix("quickr://t/\(h.topic.id.wireString)/run?scope="))
    }

    @Test func aStepShowsTheSegmentNextAndStopAndNoDueState() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await Self.tap(h)
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .open(paused: false))
        let label = try #require(topic.runDisplay?.label)
        #expect(label == "Shower")
        #expect(topic.runButtons(compact: false) == [.next, .stop])
        #expect(topic.runButtons(compact: true) == [.next], "Auto is Next while a named step remains")
        #expect(topic.runButtonTitle(.next) == "Next: Breakfast")
        #expect(topic.runButtonLabel(.next) == "Next: Breakfast")
        #expect(topic.runButtonLabel(.stop) == "Stop \(h.topic.name)")
        #expect(topic.hasOpenRun)
        #expect(topic.dueView(at: Make.t0).kind == .none)
        #expect(!topic.countsAsDue(at: Make.t0))
    }

    /// The last step: Lap is the primary (§1.2 replaces v1's Stop) and Stop stays beside it. The
    /// small size's one button is Stop: without lap types Auto keeps v1's sequence (§5.3).
    @Test func theLastStepShowsLapAndStopAndTheSmallSizeStops() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)))
        try await Self.tap(h)
        let topic = try await Self.shown(h)
        #expect(topic.runButtons(compact: false) == [.lap, .stop])
        #expect(topic.runButtonTitle(.lap) == "Lap")
        #expect(topic.runButtonLabel(.lap) == "Lap")
        #expect(!topic.isLapTyped, "T2-M1: TopicTimer.laps; every timer takes v1's Auto until then")
        #expect(topic.runButtons(compact: true) == [.stop])
    }

    /// A stopwatch (no steps) on a lap: Lap and Stop; the small size stops it (the one-press
    /// dishwasher, §5.3).
    @Test func aLapShowsLapAndStopAndTheSmallSizeStops() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        try await Self.tap(h)
        try await Self.tap(h, .lap)
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .open(paused: false))
        let label = try #require(topic.runDisplay?.label)
        #expect(label == "Lap 2")
        #expect(topic.runButtons(compact: false) == [.lap, .stop])
        #expect(topic.runButtons(compact: true) == [.stop])
        #expect(topic.runButtonTitle(.lap) == "Lap")
        #expect(topic.runButtonLabel(.lap) == "Lap")
    }

    /// A typed lap names the lap it opens (§1.3): the display's `nextLabel` during a lap, as
    /// `RunActivityDisplay` has it once I2-LA lands the §4.1 primary (today's v1 rule reads a
    /// `next_label` as Next, so the display is built here as that WP leaves it).
    @Test func aTypedLapNamesTheLapItOpens() {
        var display = RunActivityDisplay(
            state: Self.state(label: "Lap 3", stepIndex: nil, next: "Rest"), topicName: "Smoke")
        display.buttons = [.lap, .pause, .stop]
        #expect(WidgetTopic.runButtons(of: display, compact: false, lapTyped: false) == [.lap, .stop])
        #expect(WidgetTopic.runButtonTitle(.lap, of: display) == "Lap → Rest")
        #expect(WidgetTopic.runButtonLabel(.lap, of: display, topicName: "Smoke") == "Lap, then Rest")
        #expect(WidgetTopic.runButtonLabel(.stop, of: display, topicName: "Smoke") == "Stop Smoke")

        // A step's `nextLabel` belongs to Next: Lap never borrows it.
        let step = RunActivityDisplay(
            state: Self.state(label: "Shower", stepIndex: 0, next: "Breakfast"), topicName: "Morning")
        #expect(step.buttons.first == .next)
        #expect(WidgetTopic.runButtonTitle(.lap, of: step) == "Lap")
        #expect(WidgetTopic.runButtonTitle(.next, of: step) == "Next: Breakfast")
    }

    /// The one-button rule (§5.3) on an open run: a lap-typed timer's Auto is its primary, so Lap
    /// stays Lap; without lap types v1's Auto, Next while a step remains, else Stop.
    @Test func theSmallSizeFollowsTheOneButtonRule() {
        var lap = RunActivityDisplay(state: Self.state(label: "Lap 3", stepIndex: nil, next: nil), topicName: "Smoke")
        #expect(lap.buttons.first == .lap)
        #expect(WidgetTopic.runButtons(of: lap, compact: true, lapTyped: true) == [.lap])
        #expect(WidgetTopic.runButtons(of: lap, compact: true, lapTyped: false) == [.stop])
        lap.nextLabel = "Rest"
        #expect(WidgetTopic.runButtonTitle(.lap, of: lap) == "Lap → Rest")
        #expect(WidgetTopic.runButtons(of: lap, compact: true, lapTyped: true) == [.lap])

        let step = RunActivityDisplay(
            state: Self.state(label: "Shower", stepIndex: 0, next: "Breakfast"), topicName: "Morning")
        #expect(WidgetTopic.runButtons(of: step, compact: true, lapTyped: true) == [.next])
        #expect(WidgetTopic.runButtons(of: step, compact: true, lapTyped: false) == [.next])

        #expect(WidgetTopic.autoButton(primary: .lap, lapTyped: true) == .lap)
        #expect(WidgetTopic.autoButton(primary: .lap, lapTyped: false) == .stop)
        #expect(WidgetTopic.autoButton(primary: .next, lapTyped: true) == .next)
        #expect(WidgetTopic.autoButton(primary: .next, lapTyped: false) == .next)
    }

    /// Paused: the same primary and Stop (widgets have no Pause chip); the Lock Screen's Resume
    /// isn't offered here.
    @Test func pausedKeepsThePrimaryAndStop() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await Self.tap(h)
        try await Self.tap(h, .pause)
        let topic = try await Self.shown(h)
        #expect(topic.runTile == .open(paused: true))
        #expect(topic.runDisplay?.buttons == [.next, .resume, .stop])
        #expect(topic.runButtons(compact: false) == [.next, .stop])
        #expect(topic.runButtons(compact: true) == [.next])
        #expect(topic.runButtonTitle(.next) == "Next: Breakfast")
        #expect(topic.hasOpenRun)
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
        #expect(topic.runButtonTitle(.next) == "Next")
        #expect(topic.runButtonLabel(.next) == "Next")
    }

    @Test func finishingOffersAddDetailsWhichOpensTheAnswersForm() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(1)), requiresAnswers: true)
        try await Self.tap(h)
        try await Self.tap(h)
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
        try await Self.tap(h)
        let before = try await Self.shown(h)
        try await Self.tap(h)
        let after = try await Self.shown(h)
        #expect(WidgetFingerprint([before]) != WidgetFingerprint([after]))
        #expect(ControlFingerprint([before]) != ControlFingerprint([after]))
    }
}
