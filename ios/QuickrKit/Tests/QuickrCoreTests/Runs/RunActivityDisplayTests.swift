import Foundation
import QuickrCore
import Testing

/// The Live Activity's view model (timers.md §10.3, Presentation; active-surfaces.md §4.1): a
/// content state to the strings, timers and buttons the Lock Screen and Dynamic Island show, for
/// running, paused, the last step, a lap with a step pending, no steps, steps unknown, finishing
/// and ended. The states are the server's (live-activity-vectors.json).
@Suite struct RunActivityDisplayTests {
    typealias Button = RunActivityDisplay.Button

    static func display(_ name: String) throws -> RunActivityDisplay {
        RunActivityDisplay(state: try LiveActivityVectorTests.state(name), topicName: "Morning routine")
    }

    /// The vectors' run starts here (2026-10-23T08:00:00Z).
    static let t0: Double = 1_792_742_400

    @Test func running() throws {
        let d = try Self.display("update_running")
        #expect(d.phase == .running)
        #expect(d.topicName == "Morning routine")
        #expect(d.label == "Breakfast")
        #expect(d.headline == "Breakfast · 2 of 3")
        let position: String? = d.position
        #expect(position == "2 of 3")
        let stepNumber: String? = d.stepNumber
        #expect(stepNumber == "2")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == nil)
        let compact: String? = d.compactLeading
        #expect(compact == "2")
        let nextLabel: String? = d.nextLabel
        #expect(nextLabel == "Get dressed")
        let buttons: [Button] = d.buttons
        #expect(buttons == [.next, .pause, .stop])
        let primary: Button? = d.primary
        #expect(primary == .next)
        let island: [Button] = d.islandButtons
        #expect(island == [.next, .stop])
        #expect(d.title(for: .next) == "Next: Get dressed")
        #expect(d.spokenTitle(for: .next) == "Next: Get dressed")
        #expect(d.title(for: .stop) == "Stop")
        #expect(d.spokenTitle(for: .stop) == "Stop Morning routine")
        // Breakfast's "Eat up" at 12:12, 12 minutes into the step (from 2:00).
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == RunActivityDisplay.Alert(label: "Eat up", at: Self.t0 + 720))
        let endedText: String? = d.endedText
        #expect(endedText == nil)
        let segment = try #require(d.segmentTimer)
        let segmentStart: Double = segment.start
        #expect(segmentStart == Self.t0 + 120)
        let pausedAt: Double? = segment.pausedAt
        #expect(pausedAt == nil)
        let total = try #require(d.totalTimer)
        let totalStart: Double = total.start
        #expect(totalStart == Self.t0)
        let segmentMs = segment.ms(at: Self.t0 + 150)
        #expect(segmentMs == 30_000)
    }

    @Test func paused() throws {
        let d = try Self.display("update_paused")
        #expect(d.phase == .paused)
        let buttons: [Button] = d.buttons
        #expect(buttons == [.next, .resume, .stop])
        let primary: Button? = d.primary
        #expect(primary == .next)
        let island: [Button] = d.islandButtons
        #expect(island == [.next, .stop])
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == nil)
        // Paused at 200 s, in Breakfast (from 120 s), after a 30 s pause in Shower: frozen there.
        let segment = try #require(d.segmentTimer)
        let pausedAt: Double? = segment.pausedAt
        #expect(pausedAt == Self.t0 + 200)
        let segmentMs = segment.ms(at: Self.t0 + 600)
        #expect(segmentMs == 80_000)
        let total = try #require(d.totalTimer)
        let totalMs = total.ms(at: Self.t0 + 600)
        #expect(totalMs == 170_000)
    }

    @Test func nextWhilePausedFreezesTheNewSegmentAtZero() throws {
        let d = try Self.display("update_next_while_paused")
        let segment = try #require(d.segmentTimer)
        let segmentMs = segment.ms(at: Self.t0 + 600)
        #expect(segmentMs == 0)
        let total = try #require(d.totalTimer)
        let totalMs = total.ms(at: Self.t0 + 600)
        #expect(totalMs == 100_000)
    }

    @Test func lastStepOffersLapInsteadOfNext() throws {
        let d = try Self.display("update_last_step")
        #expect(d.label == "Get dressed")
        let position: String? = d.position
        #expect(position == "3 of 3")
        let nextLabel: String? = d.nextLabel
        #expect(nextLabel == nil)
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .pause, .stop])
        let primary: Button? = d.primary
        #expect(primary == .lap)
        let island: [Button] = d.islandButtons
        #expect(island == [.lap, .stop])
        // A step is open: the lap it opens has no name.
        #expect(d.title(for: .lap) == "Lap")
        #expect(d.spokenTitle(for: .lap) == "Lap")
    }

    /// An untyped lap: "Lap 2" as is (no "· lap 2"), the compact counter "L2" (one lap closed).
    @Test func noStepsShowsLapsAndTheLapCounter() throws {
        let d = try Self.display("update_no_steps")
        #expect(d.label == "Lap 2")
        #expect(d.headline == "Lap 2")
        let position: String? = d.position
        #expect(position == nil)
        let stepNumber: String? = d.stepNumber
        #expect(stepNumber == nil)
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == "L2")
        let compact: String? = d.compactLeading
        #expect(compact == "L2")
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .pause, .stop])
        #expect(d.title(for: .lap) == "Lap")
    }

    /// §4.1 replaces v1's `nextLabel != nil` test: a lap open while a step is still pending
    /// (no `step_index`) is Lap, titled plain "Lap". In a lap `next_label` is the next lap type's
    /// label, never the pending step's (timers2.md §8.1, #208), so an untyped lap has none. Not
    /// among the server's vectors, so folded here.
    @Test func lapWithAStepPendingIsLap() throws {
        let state = try Self.folded { runId, t0 in
            [
                RunEvent(id: runId, type: .start, at: t0, seg: nil, pauseId: nil),
                RunEvent(id: "0e000000-0000-4000-8000-000000000001", type: .lap, at: t0 + 10_000, seg: 0, pauseId: nil),
            ]
        }
        let stepIndex: Int? = state.stepIndex
        #expect(stepIndex == nil)
        let nextLabel: String? = state.nextLabel
        #expect(nextLabel == nil)
        let d = RunActivityDisplay(state: state, topicName: "T")
        #expect(d.label == "Lap 1")
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .pause, .stop])
        let primary: Button? = d.primary
        #expect(primary == .lap)
        let island: [Button] = d.islandButtons
        #expect(island == [.lap, .stop])
        #expect(d.title(for: .lap) == "Lap")
        #expect(d.spokenTitle(for: .lap) == "Lap")
        let lapNext: String? = d.lapNextLabel
        #expect(lapNext == nil)
        #expect(d.headline == "Lap 1")
        let compact: String? = d.compactLeading
        #expect(compact == "L1")
    }

    /// §1.3: once the state names the lap type a Lap opens, the title and VoiceOver say so.
    @Test func lapTitleNamesTheLapItOpens() throws {
        var d = try Self.display("update_no_steps")
        d.lapNextLabel = "Rest"
        #expect(d.title(for: .lap) == "Lap → Rest")
        #expect(d.spokenTitle(for: .lap) == "Lap, then Rest")
        #expect(d.title(for: .pause) == "Pause")
        #expect(d.title(for: .stop) == "Stop")
    }

    /// §1.3, #143: VoiceOver names the topic a Stop stops; the title stays "Stop".
    @Test func stopIsSpokenWithTheTopic() throws {
        for name in ["update_running", "update_no_steps", "update_tiktok_lap", "update_alert_paused"] {
            let d = try Self.display(name)
            #expect(d.title(for: .stop) == "Stop", "\(name)")
            #expect(d.spokenTitle(for: .stop) == "Stop Morning routine", "\(name)")
        }
    }

    // MARK: - M1-LA-STATE's lap and alert fields (active-surfaces.md §4.1)

    /// TikTok's second run lap (two laps closed): "Run 2 · lap 3", "L3", Lap opens a Rest, and
    /// the run lap's "Time" alert at 17:00 (15 minutes into the lap, from 2:00).
    @Test func tiktokLap() throws {
        let d = try Self.display("update_tiktok_lap")
        #expect(d.phase == .running)
        #expect(d.label == "Run 2")
        #expect(d.headline == "Run 2 · lap 3")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == "L3")
        let compact: String? = d.compactLeading
        #expect(compact == "L3")
        let position: String? = d.position
        #expect(position == nil)
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .pause, .stop])
        #expect(d.title(for: .lap) == "Lap → Rest")
        #expect(d.spokenTitle(for: .lap) == "Lap, then Rest")
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == RunActivityDisplay.Alert(label: "Time", at: Self.t0 + 1020))
    }

    /// The first run lap, "Half way" pending at 12:30.
    @Test func alertPending() throws {
        let d = try Self.display("update_alert_pending")
        #expect(d.headline == "Run 1 · lap 1")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == "L1")
        #expect(d.title(for: .lap) == "Lap → Rest")
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == RunActivityDisplay.Alert(label: "Half way", at: Self.t0 + 750))
        let primary: Button? = d.primary
        #expect(primary == .lap)
    }

    /// The same lap paused: no alert (the system timer can't pause a countdown), Resume, and
    /// the headline, counter and Lap title unchanged.
    @Test func alertPaused() throws {
        let d = try Self.display("update_alert_paused")
        #expect(d.phase == .paused)
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == nil)
        #expect(d.headline == "Run 1 · lap 1")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == "L1")
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .resume, .stop])
        #expect(d.title(for: .lap) == "Lap → Rest")
    }

    /// Even if a state carried `alert_at` while paused, the display shows none (§4.1).
    @Test func noAlertWhilePausedWhateverTheState() throws {
        var state = try LiveActivityVectorTests.state("update_alert_paused")
        state.alertAt = Self.t0 + 900
        state.alertLabel = "Half way"
        let alert: RunActivityDisplay.Alert? = RunActivityDisplay(state: state, topicName: "T").alert
        #expect(alert == nil)
    }

    /// A start of a topic whose one lap type renames laps ("Cig n"): typed, so the counter
    /// suffix, and Lap opens another Cig.
    @Test func startRenamedLaps() throws {
        let d = try Self.display("start_renamed_laps")
        #expect(d.label == "Cig 1")
        #expect(d.headline == "Cig 1 · lap 1")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == "L1")
        #expect(d.title(for: .lap) == "Lap → Cig")
        #expect(d.spokenTitle(for: .lap) == "Lap, then Cig")
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == nil)
        let primary: Button? = d.primary
        #expect(primary == .lap)
    }

    /// A run reopened into its second lap (a rest), its "Go" alert pending.
    @Test func reopened() throws {
        let d = try Self.display("update_reopened")
        #expect(d.phase == .running)
        #expect(d.headline == "Rest 1 · lap 2")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == "L2")
        #expect(d.title(for: .lap) == "Lap → Run")
        let alert = try #require(d.alert)
        #expect(alert.label == "Go")
        let at: Double = alert.at
        #expect(at == 1_792_743_160)
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .pause, .stop])
    }

    /// The payload budget nulls `alert_label` but keeps `alert_at`: the countdown, no label.
    @Test func alertWithoutItsLabel() throws {
        let d = try Self.display("payload_budget_terminal")
        let alert = try #require(d.alert)
        #expect(alert.label.isEmpty)
        let at: Double = alert.at
        #expect(at == 1_792_746_000)
    }

    /// The steps aren't known here: no lap counter, whatever `lap_count` says (the open segment
    /// may be a step), and the bare label.
    @Test func stepsUnknownHasNoLapCounter() throws {
        var state = try LiveActivityVectorTests.state("update_no_steps")
        state.stepsUnknown = true
        let d = RunActivityDisplay(state: state, topicName: "T")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == nil)
        #expect(d.headline == "Lap 2")
    }

    /// A v1 state (no `lap_count`, `lap_type`, `alert_at`): today's fallbacks (§8.2).
    @Test func aV1StateFallsBack() throws {
        var state = try LiveActivityVectorTests.state("update_tiktok_lap")
        state.lapCount = nil
        state.lapType = nil
        state.alertAt = nil
        state.alertLabel = nil
        let d = RunActivityDisplay(state: state, topicName: "T")
        #expect(d.headline == "Run 2")
        let lapCounter: String? = d.lapCounter
        #expect(lapCounter == nil)
        #expect(d.title(for: .lap) == "Lap")
        let alert: RunActivityDisplay.Alert? = d.alert
        #expect(alert == nil)
    }

    /// The device's own state for a run whose steps aren't stored: a plain Next, never Lap.
    @Test func stepsUnknownOffersAPlainNext() throws {
        var state = try LiveActivityVectorTests.state("update_no_steps")
        state.stepsUnknown = true
        let d = RunActivityDisplay(state: state, topicName: "T")
        let buttons: [Button] = d.buttons
        #expect(buttons == [.next, .pause, .stop])
        let primary: Button? = d.primary
        #expect(primary == .next)
        #expect(d.title(for: .next) == "Next")
        #expect(d.spokenTitle(for: .next) == "Next")
    }

    /// The §4.1 rule over every vector case: `steps_unknown` → Next; a step open with another
    /// following → Next; otherwise Lap. `buttons` is `[primary, pause|resume, stop]` while open
    /// and empty once ended, and `primary` is its first.
    @Test func primaryRuleHoldsOverEveryVector() throws {
        let vectors = try LiveActivityVectorTests.load()
        var open = 0
        for c in vectors.cases {
            let state = c.payload.aps.contentState
            let d = RunActivityDisplay(state: state, topicName: "T")
            let primary: Button? = d.primary
            let first: Button? = d.buttons.first
            #expect(primary == first, "\(c.name)")
            guard d.phase == .running || d.phase == .paused else {
                #expect(d.buttons.isEmpty, "\(c.name)")
                #expect(primary == nil, "\(c.name)")
                continue
            }
            open += 1
            let expected: Button = state.stepIndex != nil && state.nextLabel != nil ? .next : .lap
            let middle: Button = d.phase == .paused ? .resume : .pause
            let buttons: [Button] = d.buttons
            #expect(buttons == [expected, middle, .stop], "\(c.name)")
            let island: [Button] = d.islandButtons
            #expect(island == [expected, .stop], "\(c.name)")
            // An alert only while running, at the state's `alert_at`.
            let alertAt: Double? = d.alert?.at
            #expect(alertAt == (d.phase == .running ? state.alertAt : nil), "\(c.name)")
            #expect(d.headline.hasPrefix(state.label), "\(c.name)")
            // A lap counter exactly while a lap is open.
            #expect((d.lapCounter != nil) == (state.stepIndex == nil), "\(c.name)")
        }
        // The 7 open cases of I2-LA, M1-LA-STATE's 5 lap and alert cases (`start_renamed_laps`,
        // `update_tiktok_lap`, `update_alert_pending`, `update_alert_paused`, `update_reopened`)
        // its 2 running payload-budget cases, and #234's `typed_lap_mid_steps`.
        #expect(open == 15)
    }

    /// A content state folded from `events` over steps A, B, C.
    static func folded(_ events: (String, Int) -> [RunEvent]) throws -> RunActivityState {
        let steps = ["a", "b", "c"].map { TopicTimer.Step(key: $0, label: $0.uppercased()) }
        let t0 = RunInstant.milliseconds(Date(timeIntervalSince1970: Self.t0))
        let runId = "0a000000-0000-4000-8000-000000000000"
        let state = try RunFold.fold(runId: runId, steps: steps, events: events(runId, t0))
        return RunActivityContent.state(runId: runId, revision: 1, status: state.status, state: state, steps: steps)
    }

    @Test func finishingAsksForDetails() throws {
        let d = try Self.display("end_finishing")
        #expect(d.phase == .finishing)
        let endedText: String? = d.endedText
        #expect(endedText == "Add details")
        #expect(d.buttons.isEmpty)
        let segmentTimer: RunActivityDisplay.Timer? = d.segmentTimer
        #expect(segmentTimer == nil)
    }

    @Test func endedSaysWhatWasSaved() throws {
        let d = try Self.display("end_stopped")
        #expect(d.phase == .saved)
        let endedText: String? = d.endedText
        #expect(endedText == "Saved · 7:12")
        #expect(d.buttons.isEmpty)
        let totalTimer: RunActivityDisplay.Timer? = d.totalTimer
        #expect(totalTimer == nil)
    }

    @Test func discardedHasNoButtons() throws {
        let d = try Self.display("end_discarded")
        #expect(d.phase == .discarded)
        let endedText: String? = d.endedText
        #expect(endedText == "Discarded")
        #expect(d.buttons.isEmpty)
        let primary: Button? = d.primary
        #expect(primary == nil)
    }

    @Test func buttonsMapToTheirTaps() {
        let taps: [RunEventType] = Button.allCases.map(\.tap)
        #expect(taps == [.next, .lap, .pause, .resume, .stop])
        let titles: [String] = Button.allCases.map(\.title)
        #expect(titles == ["Next", "Lap", "Pause", "Resume", "Stop"])
    }

    /// The system-drawn timers read what the app's run screen reads (`RunPresentation`), for a
    /// pause that straddles a Next (paused at 100 s, Next at 120 s, resumed at 150 s) and one
    /// still open, at several instants after it.
    @Test func timersMatchTheRunScreen() throws {
        let steps = [TopicTimer.Step(key: "a", label: "A"), TopicTimer.Step(key: "b", label: "B")]
        let t0 = RunInstant.milliseconds(Date(timeIntervalSince1970: Self.t0))
        let runId = "0a000000-0000-4000-8000-000000000000"
        func event(_ n: Int, _ type: RunEventType, _ s: Int, seg: Int? = nil, pause: Int? = nil) -> RunEvent {
            RunEvent(
                id: n == 0 ? runId : "0e000000-0000-4000-8000-00000000000\(n)", type: type, at: t0 + s * 1000, seg: seg,
                pauseId: pause.map { "0e000000-0000-4000-8000-00000000000\($0)" })
        }
        let events = [
            event(0, .start, 0), event(1, .pause, 100), event(2, .next, 120, seg: 0),
            event(3, .resume, 150, pause: 1), event(4, .pause, 200),
        ]
        for count in [4, 5] {
            let state = try RunFold.fold(runId: runId, steps: steps, events: Array(events.prefix(count)))
            let content = RunActivityContent.state(
                runId: runId, revision: count, status: state.status, state: state, steps: steps)
            let display = RunActivityDisplay(state: content, topicName: "T")
            let segment = try #require(display.segmentTimer)
            let total = try #require(display.totalTimer)
            // From the last event on: the state says nothing about earlier instants.
            for s in [150, 170, 200, 260] where t0 + s * 1000 >= events[count - 1].at {
                let now = t0 + s * 1000
                let seconds = Self.t0 + Double(s)
                let segmentMs = segment.ms(at: seconds)
                let expectedSegment = RunPresentation.segmentMs(state, now: now)
                #expect(segmentMs == expectedSegment, "segment, \(count) events, \(s) s")
                let totalMs = total.ms(at: seconds)
                let expectedTotal = RunPresentation.activeMs(state, now: now)
                #expect(totalMs == expectedTotal, "total, \(count) events, \(s) s")
            }
        }
    }
}
