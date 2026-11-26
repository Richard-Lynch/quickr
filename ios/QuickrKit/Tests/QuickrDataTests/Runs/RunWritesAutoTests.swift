import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// R18, the Auto half (timers2.md §10, active-surfaces.md §5.3): `RunWrites.auto`, what the
/// one-button surfaces do (the Control, the small widget, the Action button, Siri). `timer.laps`
/// non-empty → Auto is the on-screen primary (Start → Next … → Lap → Lap …; never Stop);
/// `timer.laps` empty → v1's Auto (Start → Next … → Stop), so a stepless Control still stops the
/// dishwasher. Unknown steps → Next.
@Suite(.timeLimit(.minutes(5))) struct RunWritesAutoTests {
    static let laps = [TopicTimer.LapType(key: "run", label: "Run"), TopicTimer.LapType(key: "rest", label: "Rest")]

    /// One Auto press, a minute after the last; the tap it made (`start` for a start).
    private func press(_ h: OutboxHarness, _ writes: RunWrites) async throws -> String {
        h.wall.advance(by: 60)
        switch try await writes.auto(topic: h.ref, version: 1) {
        case .started(let result):
            #expect(result.started)
            return "start"
        case .tapped(let type, _, let enqueued):
            #expect(enqueued != nil, "\(type) enqueued")
            return type.rawValue
        }
    }

    @Test("R18 · untyped laps, steps: v1 Auto — Start, Next while a named step remains, then Stop")
    func untypedWithSteps() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs(.widget)
        var taps: [String] = []
        for _ in 0..<4 { taps.append(try await press(h, writes)) }
        #expect(taps == ["start", "next", "next", "stop"])
        let run = try #require(try h.localRuns().first)
        #expect(run.status == .stopped)
    }

    @Test("R18 · untyped, no steps (the dishwasher): Start, then Stop")
    func untypedStopwatch() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        let writes = h.runs(.widget)
        let taps = [try await press(h, writes), try await press(h, writes)]
        #expect(taps == ["start", "stop"])
    }

    @Test("R18 · typed laps, steps: Auto is the primary — Next while a step remains, then Lap, never Stop")
    func typedWithSteps() async throws {
        let h = try OutboxHarness()
        try h.timed(laps: Self.laps)
        let writes = h.runs(.widget)
        var taps: [String] = []
        for _ in 0..<6 { taps.append(try await press(h, writes)) }
        #expect(taps == ["start", "next", "next", "lap", "lap", "lap"])
        let run = try #require(try h.localRuns().first)
        #expect(run.isOpen)
        #expect(run.state.segments.map(\.label) == ["Shower", "Breakfast", "Out", "Run 1", "Rest 1"])
        #expect(run.state.open?.label == "Run 2")
    }

    @Test("R18 · typed laps, no steps: Start → Lap → Lap")
    func typedLapsOnly() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [], laps: Self.laps)
        let writes = h.runs(.widget)
        let taps = [try await press(h, writes), try await press(h, writes), try await press(h, writes)]
        #expect(taps == ["start", "lap", "lap"])
        let run = try #require(try h.localRuns().first)
        #expect(run.state.open?.label == "Run 2")
    }

    @Test("R18 · the pinned version isn't stored here: Next (a step may remain), whatever the laps")
    func unknownStepsIsNext() async throws {
        let h = try OutboxHarness()
        try h.timed(laps: Self.laps)
        try h.seedServerRun(version: 9)
        h.wall.advance(by: 60)
        let result = try await h.runs(.widget).auto(topic: h.ref, version: 1)
        guard case .tapped(let type, _, _) = result else {
            Issue.record("expected a tap, got \(result)")
            return
        }
        #expect(type == .next)
    }

    @Test("R18 · the Action button's Auto on a typed topic laps, and says so")
    func intentAutoLaps() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [], laps: Self.laps)
        let writes = h.runs(.siri)
        let auto = RunIntentRequest(action: .auto, topicId: h.topic.id, origin: .siri)
        _ = try await writes.perform(auto)
        h.wall.advance(by: 30)
        let result = try await writes.perform(auto)
        let expected: RunIntentOutcome = .lapped(done: "Run 1", ms: 30_000)
        #expect(result.outcome == expected)
        let types = try h.runItems.map { try h.payload($0).event.type }
        #expect(types == ["start", "lap"])
    }

    @Test("R18 · the Action button's Auto on an untyped stopwatch stops it")
    func intentAutoStops() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: [])
        let writes = h.runs(.siri)
        let auto = RunIntentRequest(action: .auto, topicId: h.topic.id, origin: .siri)
        _ = try await writes.perform(auto)
        h.wall.advance(by: 30)
        _ = try await writes.perform(auto)
        let types = try h.runItems.map { try h.payload($0).event.type }
        #expect(types == ["start", "stop"])
    }
}
