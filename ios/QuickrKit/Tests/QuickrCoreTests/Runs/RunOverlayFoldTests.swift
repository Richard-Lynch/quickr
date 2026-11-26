import Foundation
import QuickrCore
import Testing

/// `RunFold.overlay` (timers.md §8.3): this device's step-independent taps over a server state
/// whose version's steps aren't known here. The edge cases of the PWA's M3 tests
/// (`localView.test.ts`), plus taps before the open segment's start.
@Suite struct RunOverlayFoldTests {
    static let s = 1000
    static let steps = [
        TopicTimer.Step(key: "shower", label: "Shower"), TopicTimer.Step(key: "breakfast", label: "Breakfast"),
        TopicTimer.Step(key: "out", label: "Out"),
    ]

    /// The server's state: started at 0, Next at 60 s (Breakfast open since then), then `events`.
    static func server(_ events: [RunEvent] = []) throws -> RunState {
        let all = [RunEvent(id: "r1", type: .start, at: 0), RunEvent(id: "n1", type: .next, at: 60 * s, seg: 0)]
        return try RunFold.fold(runId: "r1", steps: steps, events: all + events)
    }

    @Test func aLapOpensALapSegmentAndTapsAfterTheCloseAreVoid() throws {
        let lapped = RunFold.overlay(
            try Self.server(), events: [RunEvent(id: "l1", type: .lap, at: 70 * Self.s, seg: 1)])
        let open = try #require(lapped.open)
        #expect(open.index == 2)
        #expect(open.kind == .lap)
        #expect(open.label == "Lap 1")

        let gone = RunFold.overlay(
            try Self.server(),
            events: [
                RunEvent(id: "d1", type: .discard, at: 80 * Self.s), RunEvent(id: "p2", type: .pause, at: 90 * Self.s),
            ])
        #expect(gone.status == .discarded)
        let late: RunEffect? = gone.effects["p2"]
        #expect(late == .void(.afterStop))
    }

    @Test func aTapTheServerListsAlreadyIsNotAppliedTwice() throws {
        let listed = try Self.server([RunEvent(id: "p1", type: .pause, at: 70 * Self.s)])
        let again = RunFold.overlay(listed, events: [RunEvent(id: "p1", type: .pause, at: 70 * Self.s)], pauseId: "p1")
        #expect(again.status == .paused)
        #expect(again == listed, "the listed pause is left out")

        let resumed = RunFold.overlay(
            listed,
            events: [
                RunEvent(id: "p1", type: .pause, at: 70 * Self.s),
                RunEvent(id: "u1", type: .resume, at: 80 * Self.s, pauseId: "p1"),
            ], pauseId: "p1")
        #expect(resumed.status == .running)
        let pauses: [RunPause] = resumed.pauses
        #expect(pauses == [RunPause(start: 70 * Self.s, end: 80 * Self.s)])
    }

    @Test func aResumeNamingAnotherPauseOrAnUnknownOneIsStale() throws {
        let listed = try Self.server([RunEvent(id: "p1", type: .pause, at: 70 * Self.s)])
        let resume = RunEvent(id: "u1", type: .resume, at: 80 * Self.s, pauseId: "p0")
        let other = RunFold.overlay(listed, events: [resume], pauseId: "p1")
        #expect(other.status == .paused)
        let otherEffect: RunEffect? = other.effects["u1"]
        #expect(otherEffect == .void(.stale))

        var named = resume
        named.pauseId = "p1"
        let unknown = RunFold.overlay(listed, events: [named], pauseId: nil)
        #expect(unknown.status == .paused)
        let unknownEffect: RunEffect? = unknown.effects["u1"]
        #expect(unknownEffect == .void(.stale))
    }

    @Test func aResumeBeforeItsPauseIsStale() throws {
        let listed = try Self.server([RunEvent(id: "p1", type: .pause, at: 70 * Self.s)])
        let resume = RunEvent(id: "u1", type: .resume, at: 65 * Self.s, pauseId: "p1")
        let state = RunFold.overlay(listed, events: [resume], pauseId: "p1")
        let effect: RunEffect? = state.effects["u1"]
        #expect(effect == .void(.stale))
        #expect(state.status == .paused)
        let pauses: [RunPause] = state.pauses
        #expect(pauses.isEmpty)
    }

    @Test(arguments: [RunEventType.stop, .pause, .lap])
    func aTapBeforeTheOpenSegmentsStartIsStale(type: RunEventType) throws {
        let server = try Self.server()
        let tap = RunEvent(id: "t1", type: type, at: 50 * Self.s, seg: type == .lap ? 1 : nil)
        let state = RunFold.overlay(server, events: [tap])
        let effect: RunEffect? = state.effects["t1"]
        #expect(effect == .void(.stale))
        #expect(state.status == .running)
        let segments: [RunSegment] = state.segments
        #expect(segments == server.segments)
        #expect(segments.allSatisfy { $0.activeMs >= 0 })
    }

    // MARK: - Fold v4 (timers2.md §10: `overlay` lap labelling is untyped until the version is stored)

    static let tiktok = TopicTimer(
        steps: [], laps: [TopicTimer.LapType(key: "run", label: "Run"), TopicTimer.LapType(key: "rest", label: "Rest")])

    /// A tiktok run on the server: Run 1 closed at 60 s, Rest 1 open.
    static func typedServer() throws -> RunState {
        try RunFold.fold(
            runId: "r1", timer: tiktok,
            events: [RunEvent(id: "r1", type: .start, at: 0), RunEvent(id: "l1", type: .lap, at: 60 * s, seg: 0)])
    }

    @Test func anOverlayLapIsUntypedAndCountsLaps() throws {
        let server = try Self.typedServer()
        #expect(server.open?.label == "Rest 1")
        #expect(server.nextLapType == "run")
        let lapped = RunFold.overlay(server, events: [RunEvent(id: "l2", type: .lap, at: 70 * Self.s, seg: 1)])
        let open = try #require(lapped.open)
        #expect(open.label == "Lap 2")
        #expect(open.lapType == nil)
        #expect(lapped.lapCount == 2)
        #expect(lapped.nextLapType == nil, "the next lap's type is unknown without the version")
        // The closed segment keeps the server's label and type.
        #expect(lapped.segments.last?.label == "Rest 1")
        #expect(lapped.segments.last?.lapType == "rest")
        #expect(lapped.segments.last?.eventId == nil, "an open segment carries no opener id: the server fills it")
    }

    @Test func anOverlayStopSetsTheTerminalId() throws {
        let stopped = RunFold.overlay(try Self.typedServer(), events: [RunEvent(id: "S1", type: .stop, at: 90 * Self.s)])
        #expect(stopped.status == .stopped)
        #expect(stopped.terminalId == "s1")
        #expect(stopped.lapCount == 2)
        #expect(stopped.nextLapType == nil)
        #expect(stopped.open == nil)
    }

    @Test(arguments: [RunEventType.reopen, .remove])
    func reopenAndRemoveAreLeftToTheServer(type: RunEventType) throws {
        let server = try Self.typedServer()
        let state = RunFold.overlay(server, events: [RunEvent(id: "x1", type: type, at: 80 * Self.s, target: "l1")])
        #expect(state == server)
    }
}
