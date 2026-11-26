import Foundation
import QuickrCore
import Testing

/// `EntryTimingModel` (content-display.md §3.1, §3.2): the detail's pauses as rows between the
/// segments they fall in, in time order, keeping their indexes; the list row's timing chip.
@Suite struct EntryTimingModelTests {
    static func segment(_ label: String, _ start: Int, _ end: Int, kind: RunSegmentKind = .lap) -> RunSegment {
        RunSegment(
            kind: kind, step: kind == .step ? label.lowercased() : nil, label: label, startedAt: start, endedAt: end,
            activeMs: end - start, pausedMs: 0)
    }

    static func timing(
        _ segments: [RunSegment], pauses: [RunPause] = [], activeMs: Int? = nil
    ) -> Timing {
        Timing(
            startedAt: segments.first?.startedAt ?? 0, endedAt: segments.last?.endedAt ?? 0,
            activeMs: activeMs ?? segments.reduce(0) { $0 + $1.activeMs }, pausedMs: 0, complete: true,
            edited: false, segments: segments, skipped: [], pauses: pauses)
    }

    /// A short label per row: "s<i>" for segment i, "p<j>" for pause j.
    static func labels(_ rows: [EntryTimingModel.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .segment(let index, _): "s\(index)"
            case .pause(let index, _): "p\(index)"
            }
        }
    }

    @Test func pausesSitBetweenTheSegmentsTheyFallIn() {
        let t = Self.timing(
            [
                Self.segment("Lap 1", 0, 60_000), Self.segment("Lap 2", 60_000, 150_000),
                Self.segment("Lap 3", 150_000, 200_000),
            ],
            pauses: [
                RunPause(start: 10_000, end: 20_000), RunPause(start: 30_000, end: 35_000),
                RunPause(start: 160_000, end: 170_000),
            ])
        #expect(Self.labels(EntryTimingModel.rows(t)) == ["s0", "p0", "p1", "s1", "s2", "p2"])
    }

    @Test func rowsKeepTheirOwnIndexesAndValues() {
        let laps = [Self.segment("Lap 1", 0, 60_000), Self.segment("Lap 2", 60_000, 120_000)]
        let pause = RunPause(start: 70_000, end: 90_000)
        let rows = EntryTimingModel.rows(Self.timing(laps, pauses: [pause]))
        #expect(rows == [.segment(index: 0, laps[0]), .segment(index: 1, laps[1]), .pause(index: 0, pause)])
        #expect(rows.map(\.id) == ["segment.0", "segment.1", "pause.0"], "the ids stay unique per kind")
    }

    /// A pause starting the instant a segment starts falls in that segment: after it. One that
    /// runs past its segment's end (pauses stay whole) still sits after the segment it starts in.
    @Test func boundaryAndSpanningPauses() {
        let t = Self.timing(
            [Self.segment("Shower", 0, 60_000, kind: .step), Self.segment("Dress", 60_000, 120_000, kind: .step)],
            pauses: [RunPause(start: 50_000, end: 70_000), RunPause(start: 60_000 + 30_000, end: 100_000)])
        #expect(Self.labels(EntryTimingModel.rows(t)) == ["s0", "p0", "s1", "p1"])

        let atStart = Self.timing(
            [Self.segment("Lap 1", 0, 60_000), Self.segment("Lap 2", 60_000, 120_000)],
            pauses: [RunPause(start: 60_000, end: 65_000)])
        #expect(Self.labels(EntryTimingModel.rows(atStart)) == ["s0", "s1", "p0"])
    }

    /// Out-of-order stored pauses are placed by time, keeping their stored index; a pause before
    /// the first segment comes first, and without pauses the rows are the segments.
    @Test func orderIsByTimeNotStorage() {
        let segments = [Self.segment("Lap 1", 10_000, 60_000), Self.segment("Lap 2", 60_000, 120_000)]
        let t = Self.timing(
            segments, pauses: [RunPause(start: 80_000, end: 90_000), RunPause(start: 0, end: 5_000)])
        #expect(Self.labels(EntryTimingModel.rows(t)) == ["p1", "s0", "s1", "p0"])
        #expect(Self.labels(EntryTimingModel.rows(Self.timing(segments))) == ["s0", "s1"])
        #expect(EntryTimingModel.rows(Self.timing([])).isEmpty)
    }

    // MARK: - Chip

    @Test func theChipIsTheTimingPartSpokenWithTheSegmentCount() throws {
        let laps = Self.timing(
            [
                Self.segment("Lap 1", 0, 200_000), Self.segment("Lap 2", 200_000, 500_000),
                Self.segment("Lap 3", 500_000, 760_000),
            ])
        let chip = try #require(EntryTimingModel.chip(laps, timer: TopicTimer(steps: [])))
        #expect(chip.text == "12:40 · 3 laps")
        #expect(chip.accessibilityLabel == "12 minutes 40 seconds, 3 laps")

        let one = try #require(EntryTimingModel.chip(Self.timing([Self.segment("Lap 1", 0, 61_000)]), timer: nil))
        #expect(one.text == "1:01 · 1 lap")
        #expect(one.accessibilityLabel == "1 minute 1 second, 1 lap")
    }

    /// Steps aren't in the text (the summary's timing part counts laps) but are in the count.
    @Test func stepsAreCountedInTheSpokenLabel() throws {
        let t = Self.timing([
            Self.segment("Shower", 0, 120_000, kind: .step), Self.segment("Dress", 120_000, 180_000, kind: .step),
            Self.segment("Lap 3", 180_000, 240_000),
        ])
        let chip = try #require(EntryTimingModel.chip(t, timer: nil))
        #expect(chip.text == "4:00 · 1 lap")
        #expect(chip.accessibilityLabel == "4 minutes, 2 steps, 1 lap")
        let bare = try #require(EntryTimingModel.chip(Self.timing([], activeMs: 5_000), timer: nil))
        #expect(bare.text == "0:05")
        #expect(bare.accessibilityLabel == "5 seconds")
    }

    @Test func noChipWithoutTiming() {
        #expect(EntryTimingModel.chip(nil, timer: TopicTimer(steps: [])) == nil)
    }
}
