import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// A timed topic's widget (timers.md §11.3, active-surfaces.md §5.1), from the store: idle Start;
/// open, the segment's headline and pending alert, the primary (Next while a step follows, else Lap: §4.1) and Stop, and in the
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
        #expect(!topic.isLapTyped, "no lap types: v1's Auto")
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
        #expect(topic.runDisplay?.headline == "Lap 2", "an untyped lap's headline is its label")
        #expect(topic.runButtons(compact: false) == [.lap, .stop])
        #expect(topic.runButtons(compact: true) == [.stop])
        #expect(topic.runButtonTitle(.lap) == "Lap")
        #expect(topic.runButtonLabel(.lap) == "Lap")
    }

    /// #222 from the store: a timer with lap types (Run, Rest) is lap-typed, so the small size's
    /// one Auto button is Lap, named for the lap it opens ("Lap → Rest", then "Lap → Run"), and
    /// pressing it laps (M1's `RunWrites.auto`, §5.3): Stop is never Auto.
    @Test func aLapTypedTimerLapsFromTheSmallSize() async throws {
        let h = try OutboxHarness()
        let laps = [TopicTimer.LapType(key: "run", label: "Run"), TopicTimer.LapType(key: "rest", label: "Rest")]
        try h.timed(steps: [], laps: laps)
        try await Self.tap(h)
        var topic = try await Self.shown(h)
        #expect(topic.isLapTyped)
        #expect(topic.runDisplay?.label == "Run 1")
        #expect(topic.runButtons(compact: true) == [.lap])
        #expect(topic.runButtons(compact: false) == [.lap, .stop])
        #expect(topic.runButtonTitle(.lap) == "Lap → Rest")
        #expect(topic.runButtonLabel(.lap) == "Lap, then Rest")

        try await Self.tap(h)
        topic = try await Self.shown(h)
        #expect(topic.runTile == .open(paused: false), "Auto lapped; it didn't stop")
        #expect(topic.runDisplay?.label == "Rest 1")
        #expect(topic.runButtons(compact: true) == [.lap])
        #expect(topic.runButtonTitle(.lap) == "Lap → Run")
    }

    /// A typed lap names the lap it opens (§1.3): the display's `nextLabel` during a lap, as
    /// `RunActivityDisplay` has it once I2-LA lands the §4.1 primary (today's v1 rule reads a
    /// `next_label` as Next, so the display is built here as that WP leaves it).
    @Test func aTypedLapNamesTheLapItOpens() {
        var display = RunActivityDisplay(
            state: Self.state(label: "Lap 3", stepIndex: nil, next: "Rest"), topicName: "Smoke")
        display.buttons = [.lap, .pause, .stop]
        #expect(WidgetTopic.runButtons(of: display, compact: false, lapTyped: true) == [.lap, .stop])
        #expect(WidgetTopic.runButtonTitle(.lap, of: display, lapTyped: true) == "Lap → Rest")
        #expect(WidgetTopic.runButtonLabel(.lap, of: display, lapTyped: true, topicName: "Smoke") == "Lap, then Rest")
        #expect(WidgetTopic.runButtonLabel(.stop, of: display, lapTyped: true, topicName: "Smoke") == "Stop Smoke")

        // A step's `nextLabel` belongs to Next: Lap never borrows it.
        let step = RunActivityDisplay(
            state: Self.state(label: "Shower", stepIndex: 0, next: "Breakfast"), topicName: "Morning")
        #expect(step.buttons.first == .next)
        #expect(WidgetTopic.runButtonTitle(.lap, of: step, lapTyped: true) == "Lap")
        #expect(WidgetTopic.runButtonTitle(.next, of: step, lapTyped: true) == "Next: Breakfast")
    }

    /// The one-button rule (§5.3) on an open run: a lap-typed timer's Auto is its primary, so Lap
    /// stays Lap; without lap types v1's Auto, Next while a named step remains (a lap with a step
    /// still to come included: that is what `RunWrites.auto` presses), else Stop.
    @Test func theSmallSizeFollowsTheOneButtonRule() {
        var lap = RunActivityDisplay(state: Self.state(label: "Lap 3", stepIndex: nil, next: nil), topicName: "Smoke")
        #expect(lap.buttons.first == .lap)
        #expect(WidgetTopic.runButtons(of: lap, compact: true, lapTyped: true) == [.lap])
        #expect(WidgetTopic.runButtons(of: lap, compact: true, lapTyped: false) == [.stop])
        lap.nextLabel = "Rest"
        #expect(WidgetTopic.runButtonTitle(.lap, of: lap, lapTyped: true) == "Lap → Rest")
        #expect(WidgetTopic.runButtons(of: lap, compact: true, lapTyped: true) == [.lap])

        // A lap open on a step timer with "Out" still to come (the §4.1 display, I2-LA): on-screen
        // Lap, but v1's Auto is Next, not Stop; a lap-typed timer laps. The step Lap doesn't open
        // is never its label: a plain "Lap", spoken "Lap".
        var lapBeforeStep = RunActivityDisplay(
            state: Self.state(label: "Lap 2", stepIndex: nil, next: "Out"), topicName: "Morning")
        lapBeforeStep.buttons = [.lap, .pause, .stop]
        #expect(WidgetTopic.runButtons(of: lapBeforeStep, compact: false, lapTyped: false) == [.lap, .stop])
        #expect(WidgetTopic.runButtons(of: lapBeforeStep, compact: true, lapTyped: false) == [.next])
        #expect(WidgetTopic.runButtonTitle(.next, of: lapBeforeStep, lapTyped: false) == "Next: Out")
        #expect(WidgetTopic.runButtonTitle(.lap, of: lapBeforeStep, lapTyped: false) == "Lap")
        #expect(WidgetTopic.runButtonLabel(.lap, of: lapBeforeStep, lapTyped: false, topicName: "Morning") == "Lap")
        #expect(WidgetTopic.runButtons(of: lapBeforeStep, compact: true, lapTyped: true) == [.lap])

        let step = RunActivityDisplay(
            state: Self.state(label: "Shower", stepIndex: 0, next: "Breakfast"), topicName: "Morning")
        #expect(WidgetTopic.runButtons(of: step, compact: true, lapTyped: true) == [.next])
        #expect(WidgetTopic.runButtons(of: step, compact: true, lapTyped: false) == [.next])

        #expect(WidgetTopic.autoButton(primary: .lap, nextLabel: nil, lapTyped: true) == .lap)
        #expect(WidgetTopic.autoButton(primary: .lap, nextLabel: nil, lapTyped: false) == .stop)
        #expect(WidgetTopic.autoButton(primary: .lap, nextLabel: "Out", lapTyped: false) == .next)
        #expect(WidgetTopic.autoButton(primary: .lap, nextLabel: "Rest", lapTyped: true) == .lap)
        #expect(WidgetTopic.autoButton(primary: .next, nextLabel: "Breakfast", lapTyped: true) == .next)
        #expect(WidgetTopic.autoButton(primary: .next, nextLabel: nil, lapTyped: false) == .next, "steps unknown")
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

    // MARK: - The Live Activity's fields (active-surfaces.md §5.1, §4.1)

    /// A lap-typed run (`lapTyped`: Run then Rest, Rest's "Go" 15 minutes in) on its second lap,
    /// Rest from 60 s; `pause` pauses it 30 s later.
    static func restLap(_ h: OutboxHarness, pause: Bool = false) async throws {
        try h.lapTyped()
        let runId = try await h.runs().start(topic: h.ref, version: 2).runId
        h.wall.advance(by: 60)
        _ = try await h.runs().lap(runId: runId)
        if pause {
            h.wall.advance(by: 30)
            _ = try await h.runs().pause(runId: runId)
        }
    }

    /// The widget at device time `t0 + seconds`.
    static func shown(_ h: OutboxHarness, at seconds: Double) async throws -> WidgetTopic {
        let now = Make.t0.addingTimeInterval(seconds)
        return try #require(try await WidgetReader(store: h.store).topic(id: h.topic.id, now: now))
    }

    /// A step's headline counts it, as the run screen's: "Shower · 1 of 3".
    @Test func aStepsHeadlineCountsIt() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await Self.tap(h)
        let display = try #require(try await Self.shown(h).runDisplay)
        #expect(display.headline == "Shower · 1 of 3")
        #expect(display.label == "Shower")
        #expect(display.alert == nil, "these steps have no alerts")
    }

    /// A typed lap, read with the pinned version's timer as the Live Activity is: the headline
    /// counts the lap, `next_label` names the lap type a Lap opens, and Rest's pending "Go" alert
    /// is the line under the total. The due list reads the same run.
    @Test func aTypedLapShowsItsHeadlineAndPendingAlert() async throws {
        let h = try OutboxHarness()
        try await Self.restLap(h)
        let topic = try await Self.shown(h, at: 120)
        #expect(topic.runTile == .open(paused: false))
        let display = try #require(topic.runDisplay)
        #expect(display.headline == "Rest 1 · lap 2")
        #expect(display.lapCounter == "L2")
        let lapNext: String? = display.lapNextLabel
        #expect(lapNext == "Run")
        let alert = RunActivityDisplay.Alert(label: "Go", at: Make.t0.timeIntervalSince1970 + 960)
        #expect(display.alert == alert)
        let listed = try await WidgetReader(store: h.store).dueList(now: Make.t0.addingTimeInterval(120))
        #expect(listed.first { $0.id == h.topic.id }?.runDisplay?.alert == alert)
    }

    /// `alert_at` is the next alert after the reader's `now`: once "Go" has passed there is none,
    /// and the line goes (the timeline is rebuilt then: `WidgetTimeline.reloadDate`).
    @Test func aPassedAlertIsNoLongerShown() async throws {
        let h = try OutboxHarness()
        try await Self.restLap(h)
        let before = try await Self.shown(h, at: 959)
        #expect(before.runDisplay?.alert?.label == "Go")
        let after = try await Self.shown(h, at: 961)
        #expect(after.runDisplay?.alert == nil)
        #expect(after.runDisplay?.headline == "Rest 1 · lap 2")
    }

    /// A timeline follows the alerts: from `now` "Go" is pending; from its instant (960 s) the
    /// widget reads again and, Rest having no other alert, shows none. Within `until` only.
    @Test func theTopicIsReadAgainFromEachPendingAlert() async throws {
        let h = try OutboxHarness()
        try await Self.restLap(h)
        let reader = WidgetReader(store: h.store)
        let now = Make.t0.addingTimeInterval(120)
        let go = Make.t0.addingTimeInterval(960)
        let shown = try await reader.topicByAlert(id: h.topic.id, now: now, until: now.addingTimeInterval(3600))
        #expect(shown.map(\.from) == [now, go])
        #expect(shown.first?.topic?.runDisplay?.alert?.label == "Go")
        #expect(shown.last?.topic?.runDisplay?.alert == nil)
        #expect(shown.last?.topic?.runDisplay?.headline == "Rest 1 · lap 2")
        let soon = try await reader.topicByAlert(id: h.topic.id, now: now, until: go.addingTimeInterval(-1))
        #expect(soon.map(\.from) == [now], "an alert after `until` is the reload's, not an entry")
        let paused = try OutboxHarness()
        try await Self.restLap(paused, pause: true)
        let still = try await WidgetReader(store: paused.store).topicByAlert(
            id: paused.topic.id, now: now, until: now.addingTimeInterval(3600))
        #expect(still.count == 1, "no alert is pending while paused")
    }

    /// An alert passing changes what the reader returns but not the fingerprints: the topic
    /// widget's timeline already follows it, and a Control doesn't show it, so no reload is spent.
    @Test func anAlertPassingSpendsNoReload() async throws {
        let h = try OutboxHarness()
        try await Self.restLap(h)
        let reader = WidgetReader(store: h.store)
        let before = try await reader.dueList(now: Make.t0.addingTimeInterval(959))
        let after = try await reader.dueList(now: Make.t0.addingTimeInterval(961))
        let shownBefore = try #require(before.first { $0.id == h.topic.id })
        let shownAfter = try #require(after.first { $0.id == h.topic.id })
        #expect(shownBefore.run != shownAfter.run)
        #expect(WidgetFingerprint(before) == WidgetFingerprint(after))
        #expect(ControlFingerprint(before) == ControlFingerprint(after))
    }

    /// Paused: the headline stays, the alert line goes (it cannot fire while paused).
    @Test func aPausedLapHidesTheAlert() async throws {
        let h = try OutboxHarness()
        try await Self.restLap(h, pause: true)
        let topic = try await Self.shown(h, at: 120)
        #expect(topic.runTile == .open(paused: true))
        let display = try #require(topic.runDisplay)
        #expect(display.headline == "Rest 1 · lap 2")
        #expect(display.alert == nil)
        let alertAt: Double? = topic.run?.alertAt
        #expect(alertAt == nil)
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
