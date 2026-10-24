import Foundation
import QuickrCore
import Testing

/// The Live Activity's view model (timers.md §10.3, Presentation): a content state to the strings,
/// timers and buttons the Lock Screen and Dynamic Island show, for running, paused, the last step,
/// no steps, finishing and ended. The states are the server's (live-activity-vectors.json).
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
        let position: String? = d.position
        #expect(position == "2 of 3")
        let stepNumber: String? = d.stepNumber
        #expect(stepNumber == "2")
        let nextLabel: String? = d.nextLabel
        #expect(nextLabel == "Get dressed")
        let buttons: [Button] = d.buttons
        #expect(buttons == [.next, .pause, .stop])
        let island: [Button] = d.islandButtons
        #expect(island == [.next, .stop])
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
        let island: [Button] = d.islandButtons
        #expect(island == [.next, .stop])
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
        let island: [Button] = d.islandButtons
        #expect(island == [.lap, .stop])
    }

    @Test func noStepsShowsLapsAndTheTimerGlyph() throws {
        let d = try Self.display("update_no_steps")
        #expect(d.label == "Lap 2")
        let position: String? = d.position
        #expect(position == nil)
        let stepNumber: String? = d.stepNumber
        #expect(stepNumber == nil)
        let buttons: [Button] = d.buttons
        #expect(buttons == [.lap, .pause, .stop])
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
