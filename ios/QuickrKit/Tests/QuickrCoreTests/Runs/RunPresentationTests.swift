import Foundation
import QuickrCore
import Testing

/// What the tile and the run screen show (timers.md §11.1, §11.2): clocks, the primary button,
/// Skip's target, the step list, spoken durations and the tile's state.
@Suite struct RunPresentationTests {
    static let steps = [
        TopicTimer.Step(key: "shower", label: "Shower"), TopicTimer.Step(key: "dress", label: "Dress"),
        TopicTimer.Step(key: "teeth", label: "Teeth"),
    ]

    private func fold(_ events: [RunEvent], steps: [TopicTimer.Step] = steps) throws -> RunState {
        try RunFold.fold(runId: "r", steps: steps, events: [RunEvent(id: "r", type: .start, at: 0)] + events)
    }

    @Test("Active time leaves out closed and open pauses; the segment's too")
    func clocks() throws {
        let state = try fold([
            RunEvent(id: "n1", type: .next, at: 10_000, seg: 0),
            RunEvent(id: "p1", type: .pause, at: 20_000),
            RunEvent(id: "r1", type: .resume, at: 30_000, pauseId: "p1"),
            RunEvent(id: "p2", type: .pause, at: 40_000),
        ])
        let total = RunPresentation.activeMs(state, now: 50_000)
        #expect(total == 30_000)
        let segment = RunPresentation.segmentMs(state, now: 50_000)
        #expect(segment == 20_000)
    }

    @Test("A stopped run's active time ends at its stop; its segment reads 0")
    func stoppedClocks() throws {
        let state = try fold([RunEvent(id: "s", type: .stop, at: 7_500)])
        let total = RunPresentation.activeMs(state, now: 99_000)
        #expect(total == 7_500)
        let segment = RunPresentation.segmentMs(state, now: 99_000)
        #expect(segment == 0)
    }

    @Test("Primary: Next: {next step}, then Stop on the last step; unknown steps read a plain Next")
    func primary() throws {
        let first = try fold([])
        let a = RunPresentation.primary(first, steps: Self.steps)
        #expect(a == .next(label: "Next: Dress"))
        let last = try fold([
            RunEvent(id: "n1", type: .next, at: 1, seg: 0), RunEvent(id: "n2", type: .next, at: 2, seg: 1),
        ])
        let b = RunPresentation.primary(last, steps: Self.steps)
        #expect(b == .stop)
        let unknown = RunPresentation.primary(first, steps: nil)
        #expect(unknown == .next(label: "Next"))
        let none = try fold([], steps: [])
        let c = RunPresentation.primary(none, steps: [])
        #expect(c == .stop)
    }

    @Test("Skip names the open step; after a lap, the next one; nothing when steps are unknown or none remain")
    func skipTarget() throws {
        let first = try fold([])
        let open = try #require(RunPresentation.skipTarget(first, steps: Self.steps))
        #expect(open.key == "shower")
        #expect(open.label == "Shower")
        let afterLap = try fold([
            RunEvent(id: "n1", type: .next, at: 1, seg: 0), RunEvent(id: "n2", type: .next, at: 2, seg: 1),
            RunEvent(id: "n3", type: .next, at: 3, seg: 2),
        ])
        let none = RunPresentation.skipTarget(afterLap, steps: Self.steps)
        #expect(none == nil)
        let unknown = RunPresentation.skipTarget(first, steps: nil)
        #expect(unknown == nil)
    }

    @Test("The step list: done with times, skipped, current and upcoming; then the laps")
    func rows() throws {
        let state = try fold([
            RunEvent(id: "n1", type: .next, at: 4_000, seg: 0),
            RunEvent(id: "k1", type: .skip, at: 5_000, seg: 1, step: "dress"),
            RunEvent(id: "n2", type: .next, at: 9_000, seg: 1),
            RunEvent(id: "l1", type: .lap, at: 10_000, seg: 2),
        ])
        let rows = RunPresentation.rows(state, steps: Self.steps)
        let statuses = rows.map(\.status)
        #expect(statuses == [.done, .skipped, .done, .done, .current])
        let shower: Int? = rows[0].ms
        #expect(shower == 4_000)
        // Teeth's time is the fold's (vector-tested); here only that the done row carries one.
        let teeth: Int? = rows[2].ms
        #expect(teeth != nil)
        let positions = rows.map(\.position)
        #expect(positions == [1, 2, 3, nil, nil])
        let laps = rows.map(\.isLap)
        #expect(laps == [false, false, false, true, true])
        let unknown = RunPresentation.rows(state, steps: nil)
        let lapsOnly = unknown.map(\.isLap)
        #expect(lapsOnly == [true, true])
        let idle = RunPresentation.rows(steps: Self.steps).map(\.status)
        #expect(idle == [.upcoming, .upcoming, .upcoming])
    }

    @Test("Durations are read out in words, truncated to the second")
    func spoken() {
        let zero = RunPresentation.spoken(0)
        #expect(zero == "0 seconds")
        let short = RunPresentation.spoken(252_999)
        #expect(short == "4 minutes 12 seconds")
        let long = RunPresentation.spoken(3_661_000)
        #expect(long == "1 hour 1 minute 1 second")
        let hour = RunPresentation.spoken(3_600_000)
        #expect(hour == "1 hour")
    }

    @Test("The tile's state: untimed, idle, open, paused, finishing; a run makes a topic timed")
    func tileState() {
        let untimed = RunTileState(timed: false, run: nil)
        #expect(untimed == .untimed)
        let idle = RunTileState(timed: true, run: nil)
        #expect(idle == .idle)
        let stopped = RunTileState(timed: true, run: .stopped)
        #expect(stopped == .idle)
        let running = RunTileState(timed: true, run: .running)
        #expect(running == .open(paused: false))
        let paused = RunTileState(timed: true, run: .paused)
        #expect(paused == .open(paused: true))
        let finishing = RunTileState(timed: true, run: .finishing)
        #expect(finishing == .finishing)
        // Cold load: the version (and so `timer`) isn't stored yet, but a run is: still timed.
        let coldRun = RunTileState(timed: false, run: .running)
        #expect(coldRun.isTimed)
        let coldFinishing = RunTileState(timed: false, run: .finishing)
        #expect(coldFinishing.isTimed)
    }
}
