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

    // MARK: - RunAction (timers2.md §10, R18; fixture: active-surfaces.md §1.2)

    /// Fold over a v2 timer (lap types too).
    private static func fold(_ events: [RunEvent], timer: TopicTimer) throws -> RunState {
        try RunFold.fold(runId: runId, timer: timer, events: [RunEvent(id: runId, type: .start, at: 0)] + events)
    }

    static let runId = "0a000000-0000-4000-8000-000000000000"
    static let stopId = "0e000000-0000-4000-8000-000000000001"
    static let reopenId = "0e000000-0000-4000-8000-000000000002"
    static let stop2Id = "0e000000-0000-4000-8000-000000000003"
    static let minute = 60_000

    static let lapTypes = [
        TopicTimer.LapType(key: "run", label: "Run"), TopicTimer.LapType(key: "rest", label: "Rest"),
    ]
    static let plain = TopicTimer(steps: steps)
    static let lapsOnly = TopicTimer(steps: [])
    static let tiktok = TopicTimer(steps: [], laps: lapTypes)
    static let typedSteps = TopicTimer(steps: steps, laps: lapTypes)

    /// One row of the active-surfaces.md §1.2 table. Rows 1–3 (idle) are the topic's last run
    /// seen closed: `start`, plus row 13's `reopen` while it is resumable (a topic with no run
    /// doesn't call `actions`). Rows 11 (queued reopen: I1-WRITES' "resuming" projection) and 14
    /// (busy: I1-WRITES' cooldown) are not expressible through `actions(_:status:timer:now:)`
    /// alone.
    struct ActionRow: Sendable, CustomTestStringConvertible {
        var row: String
        var events: [RunEvent]
        /// The timer the run is folded over.
        var folded: TopicTimer
        /// nil: the fold's status.
        var status: RunStatus?
        /// The timer `actions` is given (nil: steps unknown).
        var timer: TopicTimer?
        /// `now` as epoch ms.
        var now: Int = 10
        var expected: [RunAction]
        var testDescription: String { row }
    }

    private static func action(_ kind: RunAction.Kind, _ role: RunAction.Role) -> RunAction {
        RunAction(kind: kind, role: role, enabled: true)
    }

    static let actionRows: [ActionRow] = {
        let n1 = RunEvent(id: "n1", type: .next, at: 1, seg: 0)
        let n2 = RunEvent(id: "n2", type: .next, at: 2, seg: 1)
        let n3 = RunEvent(id: "n3", type: .next, at: 3, seg: 2)
        let l1 = RunEvent(id: "l1", type: .lap, at: 1, seg: 0)
        let p = RunEvent(id: "p", type: .pause, at: 4)
        let stop = RunEvent(id: stopId, type: .stop, at: 5)
        let reopen = RunEvent(id: reopenId, type: .reopen, at: 6, target: stopId)
        let removeGap = RunEvent(id: "rm", type: .remove, at: 7, target: stopId)
        let stop2 = RunEvent(id: stop2Id, type: .stop, at: 8)
        let revertDiscard = RunEvent(id: "d", type: .discard, at: 7)
        let stopS = action(.stop, .secondary)
        let pause = action(.pause, .secondary)
        let resume = action(.resume, .secondary)
        let discard = action(.discard, .destructive)
        let revert = action(.revert, .destructive)
        let lap = action(.lap(nextTypeLabel: nil), .primary)
        let start = action(.start, .primary)
        let reopen1 = action(.reopen(target: UUID(uuidString: stopId)!), .secondary)
        let reopen2 = action(.reopen(target: UUID(uuidString: stop2Id)!), .secondary)
        let window = 15 * minute
        return [
            ActionRow(
                row: "4 step open, a step remains, running", events: [], folded: plain, timer: plain,
                expected: [
                    action(.next(label: "Dress"), .primary), stopS, pause, action(.skip(label: "Shower"), .overflow),
                    discard,
                ]),
            ActionRow(
                row: "5 lap open, a step still pending, running", events: [l1], folded: plain, timer: plain,
                expected: [lap, stopS, pause, action(.skip(label: "Dress"), .overflow), discard]),
            ActionRow(
                row: "5 lap open, no step pending, running", events: [n1, n2, n3], folded: plain, timer: plain,
                expected: [lap, stopS, pause, discard]),
            ActionRow(
                row: "5 typed lap open (Rest 1): Lap → Run", events: [l1], folded: tiktok, timer: tiktok,
                expected: [action(.lap(nextTypeLabel: "Run"), .primary), stopS, pause, discard]),
            ActionRow(
                row: "6 last step open, running", events: [n1, n2], folded: plain, timer: plain,
                expected: [lap, stopS, pause, action(.skip(label: "Teeth"), .overflow), discard]),
            ActionRow(
                row: "6 last step open, typed laps: Lap → Run", events: [n1, n2], folded: typedSteps,
                timer: typedSteps,
                expected: [
                    action(.lap(nextTypeLabel: "Run"), .primary), stopS, pause,
                    action(.skip(label: "Teeth"), .overflow), discard,
                ]),
            ActionRow(
                row: "7 no steps, running (the stopwatch)", events: [], folded: lapsOnly, timer: lapsOnly,
                expected: [lap, stopS, pause, discard]),
            ActionRow(
                row: "7 typed stopwatch (Run 1 open): Lap → Rest", events: [], folded: tiktok, timer: tiktok,
                expected: [action(.lap(nextTypeLabel: "Rest"), .primary), stopS, pause, discard]),
            ActionRow(
                row: "8 paused, step open", events: [p], folded: plain, timer: plain,
                expected: [
                    action(.next(label: "Dress"), .primary), stopS, resume, action(.skip(label: "Shower"), .overflow),
                    discard,
                ]),
            ActionRow(
                row: "8 paused, lap open", events: [l1, p], folded: plain, timer: plain,
                expected: [lap, stopS, resume, action(.skip(label: "Dress"), .overflow), discard]),
            ActionRow(
                row: "8 paused, last step open", events: [n1, n2, p], folded: plain, timer: plain,
                expected: [lap, stopS, resume, action(.skip(label: "Teeth"), .overflow), discard]),
            ActionRow(
                row: "8 paused, no steps", events: [p], folded: lapsOnly, timer: lapsOnly,
                expected: [lap, stopS, resume, discard]),
            ActionRow(
                row: "9 timer nil, running", events: [], folded: plain, timer: nil,
                expected: [action(.next(label: ""), .primary), stopS, pause, discard]),
            ActionRow(
                row: "9 timer nil, paused", events: [p], folded: plain, timer: nil,
                expected: [action(.next(label: ""), .primary), stopS, resume, discard]),
            ActionRow(
                row: "10 reopened, step open: revert instead of discard", events: [stop, reopen], folded: plain,
                timer: plain,
                expected: [
                    action(.next(label: "Dress"), .primary), stopS, pause, action(.skip(label: "Shower"), .overflow),
                    revert,
                ]),
            ActionRow(
                row: "10 reopened typed stopwatch", events: [stop, reopen], folded: tiktok, timer: tiktok,
                expected: [action(.lap(nextTypeLabel: "Rest"), .primary), stopS, pause, revert]),
            ActionRow(
                row: "10 reopened, paused", events: [stop, reopen, RunEvent(id: "p2", type: .pause, at: 7)],
                folded: lapsOnly, timer: lapsOnly, expected: [lap, stopS, resume, revert]),
            ActionRow(
                row: "10 reopened, gap pause removed: still a revert", events: [stop, reopen, removeGap],
                folded: lapsOnly, timer: lapsOnly, expected: [lap, stopS, pause, revert]),
            ActionRow(
                row: "10 reopened, timer nil", events: [stop, reopen], folded: plain, timer: nil,
                expected: [action(.next(label: ""), .primary), stopS, pause, revert]),
            ActionRow(
                row: "12 finishing", events: [stop], folded: plain, status: .finishing, timer: plain,
                expected: [action(.addDetails, .primary), discard]),
            ActionRow(
                row: "1–3, 13 stopped, within the window: start, reopen(terminalId) secondary", events: [stop],
                folded: plain, timer: plain, now: 5 + window, expected: [start, reopen1]),
            ActionRow(
                row: "1, 13 stopped, timer nil: start, reopen still offered", events: [stop], folded: plain,
                timer: nil, now: 5, expected: [start, reopen1]),
            ActionRow(
                row: "3, 13 stopped, laps only: start, reopen", events: [stop], folded: lapsOnly,
                timer: lapsOnly, now: 5, expected: [start, reopen1]),
            ActionRow(
                row: "2, 13 stopped, past the window: start only", events: [stop], folded: plain, timer: plain,
                now: 5 + window + 1, expected: [start]),
            ActionRow(
                row: "13 re-stopped after a reopen: reopen names the new stop", events: [stop, reopen, stop2],
                folded: plain, timer: plain, now: 8, expected: [start, reopen2]),
            ActionRow(
                row: "13 reverted (discard after a reopen): the stop is the terminal again",
                events: [stop, reopen, revertDiscard], folded: plain, timer: plain, now: 8,
                expected: [start, reopen1]),
            ActionRow(
                row: "2 stopped without a terminal: start only", events: [], folded: plain, status: .stopped,
                timer: plain, expected: [start]),
            ActionRow(
                row: "2 discarded: start only", events: [RunEvent(id: "d", type: .discard, at: 5)], folded: plain,
                timer: plain, expected: [start]),
            ActionRow(
                row: "2 discarded with a terminal still set: start only (only a stopped run reopens)",
                events: [stop], folded: plain, status: .discarded, timer: plain, now: 5, expected: [start]),
        ]
    }()

    @Test("actions: the §1.2 table row by row (display order, roles, ids)", arguments: actionRows)
    func actionsTable(_ row: ActionRow) throws {
        let state = try Self.fold(row.events, timer: row.folded)
        let now = RunInstant.date(row.now)
        let actions = RunPresentation.actions(state, status: row.status ?? state.status, timer: row.timer, now: now)
        #expect(actions == row.expected)
        #expect(actions.map(\.id) == row.expected.map(\.id))
        #expect(actions.allSatisfy { $0.enabled })
    }

    @Test("Exactly one primary in every state; Stop is never primary; start only when closed")
    func onePrimary() throws {
        for row in Self.actionRows {
            let state = try Self.fold(row.events, timer: row.folded)
            let status = row.status ?? state.status
            let actions = RunPresentation.actions(
                state, status: status, timer: row.timer, now: RunInstant.date(row.now))
            #expect(actions.count { $0.role == .primary } == 1, "\(row.row)")
            #expect(!actions.contains { $0.kind == .stop && $0.role == .primary }, "\(row.row)")
            let closed = status == .stopped || status == .discarded
            #expect(
                actions.first?.kind == .start || !closed, "\(row.row): a closed run is idle, start is its primary")
            #expect(actions.contains { $0.kind == .start } == closed, "\(row.row): start only for a closed run")
            #expect(
                actions.filter { $0.id == "reopen" }.allSatisfy { $0.role == .secondary },
                "\(row.row): reopen is secondary")
            #expect(
                actions.filter { $0.id == "revert" || $0.id == "discard" }.allSatisfy { $0.role == .destructive },
                "\(row.row): revert and discard are destructive")
            #expect(
                !(actions.contains { $0.kind == .discard } && actions.contains { $0.kind == .revert }),
                "\(row.row): revert replaces discard")
            let ranks = actions.map(\.role).map { role -> Int in
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

    // MARK: - headline

    @Test("headline: a step reads its position of the steps; a typed lap its lap number; an untyped lap its label")
    func headline() throws {
        let step = try Self.fold([], timer: Self.plain)
        #expect(
            RunPresentation.headline(step, status: .running, timer: Self.plain)
                == Headline(text: "Shower · 1 of 3", counter: nil))
        let second = try Self.fold([RunEvent(id: "n1", type: .next, at: 1, seg: 0)], timer: Self.plain)
        #expect(
            RunPresentation.headline(second, status: .running, timer: Self.plain)
                == Headline(text: "Dress · 2 of 3", counter: nil))
        // The steps unknown: the label alone.
        #expect(RunPresentation.headline(second, status: .running, timer: nil) == Headline(text: "Dress", counter: nil))

        let typed = try Self.fold(
            [
                RunEvent(id: "l1", type: .lap, at: 1, seg: 0), RunEvent(id: "l2", type: .lap, at: 2, seg: 1),
                RunEvent(id: "l3", type: .lap, at: 3, seg: 2),
            ], timer: Self.tiktok)
        #expect(
            RunPresentation.headline(typed, status: .running, timer: Self.tiktok)
                == Headline(text: "Rest 2 · lap 4", counter: "L4"))

        let untyped = try Self.fold(
            [RunEvent(id: "l1", type: .lap, at: 1, seg: 0), RunEvent(id: "l2", type: .lap, at: 2, seg: 1)],
            timer: Self.lapsOnly)
        #expect(
            RunPresentation.headline(untyped, status: .running, timer: Self.lapsOnly)
                == Headline(text: "Lap 3", counter: "L3"))
        #expect(
            RunPresentation.headline(untyped, status: .running, timer: nil) == Headline(text: "Lap 3", counter: "L3"))

        let stopped = try Self.fold([RunEvent(id: Self.stopId, type: .stop, at: 5)], timer: Self.plain)
        #expect(
            RunPresentation.headline(stopped, status: .finishing, timer: Self.plain)
                == Headline(text: "Running", counter: nil))
        #expect(
            RunPresentation.headline(stopped, status: .paused, timer: Self.plain)
                == Headline(text: "Paused", counter: nil))
    }

    // MARK: - alertLine

    static func alert(_ key: String, _ label: String, _ ms: Int) -> TopicTimer.Alert {
        TopicTimer.Alert(key: key, label: label, at: "\(ms)ms", atMs: ms)
    }

    static let alerted = TopicTimer(
        steps: [
            TopicTimer.Step(
                key: "shower", label: "Shower",
                alerts: [alert("done", "Done", 60_000), alert("half", "Half way", 30_000)]),
            TopicTimer.Step(key: "dress", label: "Dress"),
        ],
        laps: [
            TopicTimer.LapType(key: "run", label: "Run"),
            TopicTimer.LapType(
                key: "rest", label: "Rest", alerts: [alert("b", "Go", 20_000), alert("a", "Ready", 20_000)]),
        ])

    @Test("alertLine: the next alert of the open segment and its countdown, by at_ms then position")
    func alertLine() throws {
        let state = try Self.fold([], timer: Self.alerted)
        func line(_ s: RunState, _ now: Int, _ timer: TopicTimer? = RunPresentationTests.alerted) -> String? {
            RunPresentation.alertLine(s, timer: timer, now: RunInstant.date(now))
        }
        #expect(line(state, 18_000) == "Half way · in 0:12")
        #expect(line(state, 30_000) == "Done · in 0:30", "an alert fires when active time reaches at_ms")
        #expect(line(state, 40_500) == "Done · in 0:19")
        #expect(line(state, 60_000) == nil, "none remain")
        #expect(line(state, 18_000, nil) == nil, "steps unknown")

        // Paused time doesn't count; nil while paused.
        let paused = try Self.fold([RunEvent(id: "p", type: .pause, at: 10_000)], timer: Self.alerted)
        #expect(line(paused, 25_000) == nil)
        let resumed = try Self.fold(
            [RunEvent(id: "p", type: .pause, at: 10_000), RunEvent(id: "u", type: .resume, at: 20_000, pauseId: "p")],
            timer: Self.alerted)
        #expect(line(resumed, 30_000) == "Half way · in 0:10")

        // A segment without alerts: nil.
        let dress = try Self.fold([RunEvent(id: "n1", type: .next, at: 1_000, seg: 0)], timer: Self.alerted)
        #expect(line(dress, 2_000) == nil)

        // A lap type's alerts; equal at_ms: the first in position.
        let rest = try Self.fold(
            [
                RunEvent(id: "n1", type: .next, at: 1_000, seg: 0), RunEvent(id: "n2", type: .next, at: 2_000, seg: 1),
                RunEvent(id: "l1", type: .lap, at: 3_000, seg: 2),
            ], timer: Self.alerted)
        #expect(rest.open?.lapType == "rest")
        #expect(line(rest, 8_000) == "Go · in 0:15")

        // A closed run: nil.
        let stopped = try Self.fold([RunEvent(id: Self.stopId, type: .stop, at: 5_000)], timer: Self.alerted)
        #expect(line(stopped, 6_000) == nil)
    }

    @Test("resumable stays false here: the latest-stop and open-run rules are I1-WRITES' (store context)")
    func resumableIsWrites() throws {
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
