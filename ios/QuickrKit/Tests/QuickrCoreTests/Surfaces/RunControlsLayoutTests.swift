import Foundation
import QuickrCore
import Testing

/// Where each run action goes (active-surfaces.md §1, §2.2, §3.2), table-driven over the 14 rows of
/// the §1.2 state table. Every row M1's `RunPresentation.actions` expresses is folded and passed
/// through it (#153). By hand: row 1 (a topic with no run doesn't call `actions`), and rows 11 (a
/// queued reopen) and 14 (busy), which are the caller's (`RunActions.actions(for:)`, QuickrData).
@Suite struct RunControlsLayoutTests {
    static let steps = [
        TopicTimer.Step(key: "shower", label: "Shower"), TopicTimer.Step(key: "dress", label: "Dress"),
        TopicTimer.Step(key: "teeth", label: "Teeth"),
    ]
    static let terminal = UUID(uuidString: "00000000-0000-4000-8000-000000000013")!
    static let minute = 60_000

    struct Row: Sendable, CustomTestStringConvertible {
        var row: String
        var actions: [RunAction]
        var primary: RunAction?
        var secondaries: [RunAction]
        var overflow: [RunAction]
        var tile: RunControlsLayout.Tile
        var testDescription: String { row }
    }

    private static func a(_ kind: RunAction.Kind, _ role: RunAction.Role, enabled: Bool = true) -> RunAction {
        RunAction(kind: kind, role: role, enabled: enabled)
    }

    /// M1's actions for a run folded from `start` plus `events`, at `now` (epoch ms).
    private static func actions(
        _ events: [RunEvent], steps: [TopicTimer.Step] = steps, status: RunStatus? = nil, timer: TopicTimer?,
        now: Int = 10
    ) -> [RunAction] {
        // A fixture that doesn't fold is a broken test: crash rather than skip the row.
        let state = try! RunFold.fold(
            runId: "r", steps: steps, events: [RunEvent(id: "r", type: .start, at: 0)] + events)
        return RunPresentation.actions(state, status: status ?? state.status, timer: timer, now: RunInstant.date(now))
    }

    static let rows: [Row] = {
        let timer = TopicTimer(steps: steps)
        let lapsOnly = TopicTimer(steps: [])
        let n1 = RunEvent(id: "n1", type: .next, at: 1, seg: 0)
        let n2 = RunEvent(id: "n2", type: .next, at: 2, seg: 1)
        let l1 = RunEvent(id: "l1", type: .lap, at: 1, seg: 0)
        let p = RunEvent(id: "p", type: .pause, at: 4)
        let x = RunEvent(id: terminal.wireString, type: .stop, at: 5)
        let reopened = RunEvent(id: "0e000000-0000-4000-8000-000000000002", type: .reopen, at: 6, target: x.id)
        let start = a(.start, .primary)
        let reopen = a(.reopen(target: terminal), .secondary)
        let stop = a(.stop, .secondary)
        let pause = a(.pause, .secondary)
        let resume = a(.resume, .secondary)
        let discard = a(.discard, .destructive)
        let revert = a(.revert, .destructive)
        let lap = a(.lap(nextTypeLabel: nil), .primary)
        let next = a(.next(label: "Dress"), .primary)
        let skipShower = a(.skip(label: "Shower"), .overflow)
        func open(_ primary: RunAction, _ toggle: RunAction) -> RunControlsLayout.Tile {
            .init(primary: primary, stop: stop, pauseResume: toggle)
        }
        let none = RunControlsLayout.Tile(primary: nil, stop: nil, pauseResume: nil)
        return [
            Row(
                row: "1 idle, timer nil", actions: [start], primary: start, secondaries: [], overflow: [],
                tile: .init(primary: start, stop: nil, pauseResume: nil)),
            Row(
                row: "2 idle, timer with steps, latest entry resumable",
                actions: actions([x], status: .stopped, timer: timer), primary: start, secondaries: [reopen],
                overflow: [], tile: .init(primary: start, stop: nil, pauseResume: nil)),
            Row(
                row: "3 idle, laps only (as 2)", actions: actions([x], steps: [], status: .stopped, timer: lapsOnly),
                primary: start, secondaries: [reopen], overflow: [],
                tile: .init(primary: start, stop: nil, pauseResume: nil)),
            Row(
                row: "4 step open, a step remains, running", actions: actions([], timer: timer), primary: next,
                secondaries: [stop, pause], overflow: [skipShower, discard], tile: open(next, pause)),
            Row(
                row: "5 lap open, a step pending, running", actions: actions([l1], timer: timer), primary: lap,
                secondaries: [stop, pause], overflow: [a(.skip(label: "Dress"), .overflow), discard],
                tile: open(lap, pause)),
            Row(
                row: "6 last step open, running", actions: actions([n1, n2], timer: timer), primary: lap,
                secondaries: [stop, pause], overflow: [a(.skip(label: "Teeth"), .overflow), discard],
                tile: open(lap, pause)),
            Row(
                row: "7 no steps, running (the stopwatch)", actions: actions([], steps: [], timer: lapsOnly),
                primary: lap, secondaries: [stop, pause], overflow: [discard], tile: open(lap, pause)),
            Row(
                row: "8 paused (row 4)", actions: actions([p], timer: timer), primary: next,
                secondaries: [stop, resume], overflow: [skipShower, discard], tile: open(next, resume)),
            Row(
                row: "9 open, timer nil", actions: actions([], timer: nil), primary: a(.next(label: ""), .primary),
                secondaries: [stop, pause], overflow: [discard], tile: open(a(.next(label: ""), .primary), pause)),
            Row(
                row: "10 open after a reopen (row 4)", actions: actions([x, reopened], timer: timer), primary: next,
                secondaries: [stop, pause], overflow: [skipShower, revert], tile: open(next, pause)),
            Row(
                row: "11 queued reopen not yet acked", actions: [], primary: nil, secondaries: [], overflow: [],
                tile: none),
            Row(
                row: "12 finishing", actions: actions([x], status: .finishing, timer: timer),
                primary: a(.addDetails, .primary), secondaries: [], overflow: [discard],
                tile: .init(primary: a(.addDetails, .primary), stop: nil, pauseResume: nil)),
            Row(
                // Row 13 seen from the topic (§1.2 decision): `start` beside the resumable stop's
                // `reopen`, as row 2; the entry detail's reopen alone is M4's.
                row: "13 stopped, entry resumable",
                actions: actions([x], status: .stopped, timer: timer, now: 5 + minute),
                primary: start, secondaries: [reopen], overflow: [],
                tile: .init(primary: start, stop: nil, pauseResume: nil)),
            Row(
                // M1's idle rows (§1.2): a stopped run past OQ-1's window is `start` alone.
                row: "13 stopped, past the window",
                actions: actions([x], status: .stopped, timer: timer, now: 5 + 16 * minute),
                primary: a(.start, .primary), secondaries: [], overflow: [],
                tile: .init(primary: a(.start, .primary), stop: nil, pauseResume: nil)),
            {
                let off = { (action: RunAction) in a(action.kind, action.role, enabled: false) }
                return Row(
                    row: "14 busy (row 4)", actions: [next, stop, pause, skipShower, discard].map(off),
                    primary: off(next), secondaries: [off(stop), off(pause)],
                    overflow: [off(skipShower), off(discard)],
                    tile: .init(primary: off(next), stop: off(stop), pauseResume: off(pause)))
            }(),
        ]
    }()

    @Test("§1.2 table: primary, secondaries, overflow and the tile per row", arguments: rows)
    func table(_ row: Row) {
        let layout = RunControlsLayout(actions: row.actions)
        #expect(layout.primary == row.primary)
        #expect(layout.secondaries == row.secondaries)
        #expect(layout.overflow == row.overflow)
        #expect(RunControlsLayout.tile(actions: row.actions) == row.tile)
    }

    @Test("Every action lands in exactly one slot (no duplication, nothing dropped)", arguments: rows)
    func noDuplication(_ row: Row) {
        let layout = RunControlsLayout(actions: row.actions)
        let placed = [layout.primary].compactMap { $0 } + layout.secondaries + layout.overflow
        #expect(placed.count == row.actions.count)
        #expect(Set(placed) == Set(row.actions))
    }

    @Test("Placement reads the role only: reopen and revert land in their role's slot, overflow included")
    func byRole() {
        let reopen = Self.a(.reopen(target: Self.terminal), .overflow)
        let revert = Self.a(.revert, .destructive)
        let layout = RunControlsLayout(actions: [
            revert, Self.a(.lap(nextTypeLabel: "Rest"), .primary), reopen, Self.a(.stop, .secondary),
        ])
        #expect(layout.primary?.kind == .lap(nextTypeLabel: "Rest"))
        #expect(layout.secondaries.map(\.id) == ["stop"])
        #expect(layout.overflow == [reopen, revert])
    }

    @Test("A second primary goes to the overflow ahead of destructive actions, never beside the first")
    func secondPrimary() {
        let layout = RunControlsLayout(actions: [
            Self.a(.discard, .destructive), Self.a(.start, .primary), Self.a(.addDetails, .primary),
        ])
        #expect(layout.primary?.id == "start")
        #expect(layout.overflow.map(\.id) == ["addDetails", "discard"])
    }
}
