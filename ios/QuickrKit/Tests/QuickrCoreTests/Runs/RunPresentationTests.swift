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

    @Test("A paused clock read with a stale now (before the pause) shows the pause's time, never less")
    func stalePausedNow() throws {
        let state = try fold([
            RunEvent(id: "n1", type: .next, at: 10_000, seg: 0), RunEvent(id: "p1", type: .pause, at: 20_000),
        ])
        let total = RunPresentation.activeMs(state, now: 15_000)
        #expect(total == 20_000)
        let segment = RunPresentation.segmentMs(state, now: 15_000)
        #expect(segment == 10_000)
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

    // MARK: - RunAction (timers2.md §10, R18 stub half; fixture: active-surfaces.md §1.2)

    /// One row of the active-surfaces.md §1.2 table, as far as today's types express it (T2-M1
    /// stub half). Rows 1–3 (idle: no `RunState` exists for an idle topic), 10 (after a reopen),
    /// 11 (queued reopen) and 14 (busy) need v2 state and are not expressible yet; row 13 is
    /// pinned as today's model yields it (`resumable` is false until I1-CORE: `[]`).
    struct ActionRow: Sendable, CustomTestStringConvertible {
        var row: String
        var events: [RunEvent]
        var steps: [TopicTimer.Step]
        /// nil: the fold's status.
        var status: RunStatus?
        var timer: TopicTimer?
        var expected: [RunAction]
        var testDescription: String { row }
    }

    private static func action(_ kind: RunAction.Kind, _ role: RunAction.Role) -> RunAction {
        RunAction(kind: kind, role: role, enabled: true)
    }

    static let actionRows: [ActionRow] = {
        let timer = TopicTimer(steps: steps)
        let lapsOnly = TopicTimer(steps: [])
        let n1 = RunEvent(id: "n1", type: .next, at: 1, seg: 0)
        let n2 = RunEvent(id: "n2", type: .next, at: 2, seg: 1)
        let n3 = RunEvent(id: "n3", type: .next, at: 3, seg: 2)
        let l1 = RunEvent(id: "l1", type: .lap, at: 1, seg: 0)
        let p = RunEvent(id: "p", type: .pause, at: 4)
        let stop = RunEvent(id: "x", type: .stop, at: 5)
        let stopS = action(.stop, .secondary)
        let pause = action(.pause, .secondary)
        let resume = action(.resume, .secondary)
        let discard = action(.discard, .destructive)
        let lap = action(.lap(nextTypeLabel: nil), .primary)
        return [
            ActionRow(
                row: "4 step open, a step remains, running", events: [], steps: steps, status: nil, timer: timer,
                expected: [
                    action(.next(label: "Dress"), .primary), stopS, pause, action(.skip(label: "Shower"), .overflow),
                    discard,
                ]),
            ActionRow(
                row: "5 lap open, a step still pending, running", events: [l1], steps: steps, status: nil,
                timer: timer, expected: [lap, stopS, pause, action(.skip(label: "Dress"), .overflow), discard]),
            ActionRow(
                row: "5 lap open, no step pending, running", events: [n1, n2, n3], steps: steps, status: nil,
                timer: timer, expected: [lap, stopS, pause, discard]),
            ActionRow(
                row: "6 last step open, running", events: [n1, n2], steps: steps, status: nil, timer: timer,
                expected: [lap, stopS, pause, action(.skip(label: "Teeth"), .overflow), discard]),
            ActionRow(
                row: "7 no steps, running (the stopwatch)", events: [], steps: [], status: nil, timer: lapsOnly,
                expected: [lap, stopS, pause, discard]),
            ActionRow(
                row: "8 paused, step open", events: [p], steps: steps, status: nil, timer: timer,
                expected: [
                    action(.next(label: "Dress"), .primary), stopS, resume, action(.skip(label: "Shower"), .overflow),
                    discard,
                ]),
            ActionRow(
                row: "8 paused, lap open", events: [l1, p], steps: steps, status: nil, timer: timer,
                expected: [lap, stopS, resume, action(.skip(label: "Dress"), .overflow), discard]),
            ActionRow(
                row: "8 paused, last step open", events: [n1, n2, p], steps: steps, status: nil, timer: timer,
                expected: [lap, stopS, resume, action(.skip(label: "Teeth"), .overflow), discard]),
            ActionRow(
                row: "8 paused, no steps", events: [p], steps: [], status: nil, timer: lapsOnly,
                expected: [lap, stopS, resume, discard]),
            ActionRow(
                row: "9 timer nil, running", events: [], steps: steps, status: nil, timer: nil,
                expected: [action(.next(label: "Next"), .primary), stopS, pause, discard]),
            ActionRow(
                row: "9 timer nil, paused", events: [p], steps: steps, status: nil, timer: nil,
                expected: [action(.next(label: "Next"), .primary), stopS, resume, discard]),
            ActionRow(
                row: "12 finishing", events: [stop], steps: steps, status: .finishing, timer: timer,
                expected: [action(.addDetails, .primary), discard]),
            ActionRow(
                row: "13 stopped, not resumable today (stub half)", events: [stop], steps: steps, status: .stopped,
                timer: timer, expected: []),
            ActionRow(
                row: "13 discarded", events: [stop], steps: steps, status: .discarded, timer: timer, expected: []),
        ]
    }()

    @Test("actions: the §1.2 table row by row (display order, roles, ids)", arguments: actionRows)
    func actionsTable(_ row: ActionRow) throws {
        let state = try fold(row.events, steps: row.steps)
        let actions = RunPresentation.actions(state, status: row.status ?? state.status, timer: row.timer, now: Date())
        #expect(actions == row.expected)
        #expect(actions.map(\.id) == row.expected.map(\.id))
        #expect(actions.allSatisfy { $0.enabled })
    }

    @Test("Exactly one primary while a run is open or finishing; Stop is never primary")
    func onePrimary() throws {
        for row in Self.actionRows where row.status != .stopped && row.status != .discarded {
            let state = try fold(row.events, steps: row.steps)
            let actions = RunPresentation.actions(
                state, status: row.status ?? state.status, timer: row.timer, now: Date())
            #expect(actions.count { $0.role == .primary } == 1, "\(row.row)")
            #expect(!actions.contains { $0.kind == .stop && $0.role == .primary }, "\(row.row)")
            let order = actions.map(\.role)
            let ranks = order.map { role -> Int in
                switch role {
                case .primary: 0
                case .secondary: 1
                case .overflow: 2
                case .destructive: 3
                }
            }
            #expect(ranks == ranks.sorted(), "\(row.row): display order is primary, secondaries, overflow, destructive")
        }
    }

    @Test("Kind is complete from day one; ids are stable per kind")
    func actionIds() {
        let target = UUID()
        let kinds: [(RunAction.Kind, String)] = [
            (.start, "start"), (.next(label: "Dress"), "next"), (.lap(nextTypeLabel: "Rest"), "lap"),
            (.skip(label: "Shower"), "skip"), (.pause, "pause"), (.resume, "resume"), (.stop, "stop"),
            (.addDetails, "addDetails"), (.reopen(target: target), "reopen"), (.revert, "revert"),
            (.discard, "discard"),
        ]
        for (kind, id) in kinds {
            let action = RunAction(kind: kind, role: .overflow, enabled: false)
            #expect(action.id == id)
            #expect(action.enabled == false)
        }
    }

    @Test("headline: the open segment's label today; Running/Paused when nothing is open; no counter yet")
    func headlineStub() throws {
        let timer = TopicTimer(steps: Self.steps)
        let step = try fold([])
        let a = RunPresentation.headline(step, status: .running, timer: timer)
        #expect(a == Headline(text: "Shower", counter: nil))
        let lap = try fold([RunEvent(id: "l1", type: .lap, at: 1, seg: 0)])
        let b = RunPresentation.headline(lap, status: .running, timer: nil)
        #expect(b == Headline(text: "Lap 1", counter: nil))
        let stopped = try fold([RunEvent(id: "x", type: .stop, at: 5)])
        let c = RunPresentation.headline(stopped, status: .finishing, timer: timer)
        #expect(c == Headline(text: "Running", counter: nil))
        let paused = try fold([RunEvent(id: "x", type: .stop, at: 5)])
        let d = RunPresentation.headline(paused, status: .paused, timer: timer)
        #expect(d == Headline(text: "Paused", counter: nil))
    }

    @Test("alertLine is nil and resumable false until I1-CORE / I1-WRITES fill them")
    func stubs() throws {
        let state = try fold([])
        #expect(RunPresentation.alertLine(state, timer: TopicTimer(steps: Self.steps), now: Date()) == nil)
        let now = Date()
        let entry = Entry(
            id: UUID(), topicId: UUID(), version: 1, revision: 1, source: "ios", channel: .ios, capturedAt: now,
            createdAt: now, updatedAt: now, answers: [:],
            timing: Timing(
                startedAt: 0, endedAt: 5, activeMs: 5, pausedMs: 0, complete: true, edited: false, segments: [],
                skipped: [], pauses: []))
        #expect(RunPresentation.resumable(entry, now: now) == false)
    }
}
