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

    // MARK: - Remove, Resume run, lap-type badges (content-display.md §3.2)

    static let typed: Timing = {
        func lap(_ label: String, _ a: Int, _ b: Int, _ type: String?, _ event: String?, _ by: RunOpenedBy?)
            -> RunSegment
        {
            RunSegment(
                kind: .lap, step: nil, label: label, startedAt: a, endedAt: b, activeMs: b - a, pausedMs: 0,
                lapType: type, eventId: event, openedBy: by)
        }
        var t = timing(
            [
                RunSegment(
                    kind: .step, step: "warm", label: "Warm up", startedAt: 0, endedAt: 60_000, activeMs: 60_000,
                    pausedMs: 0, eventId: nil, openedBy: .start),
                lap("Run 1", 60_000, 120_000, "run", "e-next", .next),
                lap("Rest 1", 120_000, 180_000, "rest", "e-lap", .lap),
                lap("Lap 3", 180_000, 240_000, nil, nil, nil),
            ],
            pauses: [RunPause(start: 130_000, end: 140_000, id: "p-1"), RunPause(start: 200_000, end: 210_000)])
        t.terminalId = "t-1"
        return t
    }()

    /// Lap rows (not the first, not a step) and pause rows with an id have Remove; a lap a `next`
    /// opened has it disabled; a null id (pre-v2, A12) has none.
    @Test func removeIsOfferedOnLapsAndPausesWithIds() {
        let rows = EntryTimingModel.rows(Self.typed)
        #expect(Self.labels(rows) == ["s0", "s1", "s2", "p0", "s3", "p1"])
        let removes = rows.map { EntryTimingModel.remove($0, in: Self.typed) }
        #expect(removes[0] == nil, "a step, and the first segment")
        #expect(
            removes[1]
                == EntryTimingModel.Remove(
                    target: "e-next", enabled: false, title: "Remove this lap?",
                    message: "Its time joins the previous segment.", identifier: "entry.timing.remove.1",
                    label: "Remove Run 1", hint: "Starts at a step boundary: change it with Edit times"))
        #expect(removes[2]?.target == "e-lap" && removes[2]?.enabled == true)
        #expect(
            removes[3]
                == EntryTimingModel.Remove(
                    target: "p-1", enabled: true, title: "Remove this pause?", message: "Its time becomes active.",
                    identifier: "entry.timing.pause.remove.0", label: "Remove pause, 10 seconds"))
        #expect(removes[4] == nil, "a lap without an event id")
        #expect(removes[5] == nil, "a pause without an id")
    }

    /// Review R5: each Remove names its row for VoiceOver ("Remove Rest 1", "Remove pause, 10
    /// seconds"), and a disabled one says why, for both step-boundary openers (`next`, `skip`).
    @Test func removeNamesItsRowAndSaysWhyItIsDisabled() throws {
        let removes = EntryTimingModel.rows(Self.typed).map { EntryTimingModel.remove($0, in: Self.typed) }
        #expect(removes[2]?.label == "Remove Rest 1" && removes[2]?.hint == nil)
        #expect(removes[3]?.label == "Remove pause, 10 seconds" && removes[3]?.hint == nil)
        #expect(removes[1]?.hint == EntryTimingModel.stepBoundaryHint)
        var skipped = Self.typed
        skipped.segments[1].openedBy = .skip
        let skip = try #require(EntryTimingModel.remove(EntryTimingModel.rows(skipped)[1], in: skipped))
        #expect(!skip.enabled && skip.hint == "Starts at a step boundary: change it with Edit times")
    }

    @Test func theFirstSegmentNeverHasRemoveEvenAsALap() {
        let t = Self.timing([
            RunSegment(
                kind: .lap, step: nil, label: "Lap 1", startedAt: 0, endedAt: 1_000, activeMs: 1_000, pausedMs: 0,
                eventId: "e-0", openedBy: .lap)
        ])
        #expect(EntryTimingModel.rows(t).compactMap { EntryTimingModel.remove($0, in: t) }.isEmpty)
    }

    @Test func anEditedTimingHasNoRemove() {
        var t = Self.typed
        t.edited = true
        #expect(EntryTimingModel.rows(t).compactMap { EntryTimingModel.remove($0, in: t) }.isEmpty)
    }

    /// Resume run: within 7 days of the start, unedited, not pending, no local run on the topic.
    @Test func resumeRunsRules() {
        let start = Date(timeIntervalSince1970: 1_792_497_600)
        var timing = Self.typed
        timing.startedAt = RunInstant.milliseconds(start)
        timing.endedAt = timing.startedAt + 240_000
        let entry = Entry(
            id: UUID(), topicId: UUID(), version: 1, revision: 1, source: "ios", channel: .ios, capturedAt: start,
            createdAt: start, updatedAt: start, answers: [:], timing: timing)
        let soon = start.addingTimeInterval(3_600)
        #expect(EntryTimingModel.offersResume(entry, pending: false, topicHasLocalRun: false, now: soon))
        #expect(!EntryTimingModel.offersResume(entry, pending: true, topicHasLocalRun: false, now: soon))
        #expect(!EntryTimingModel.offersResume(entry, pending: false, topicHasLocalRun: true, now: soon))
        let week = start.addingTimeInterval(7 * 86_400)
        #expect(EntryTimingModel.offersResume(entry, pending: false, topicHasLocalRun: false, now: week))
        #expect(
            !EntryTimingModel.offersResume(
                entry, pending: false, topicHasLocalRun: false, now: week.addingTimeInterval(1)))
        var edited = entry
        edited.timing?.edited = true
        #expect(!EntryTimingModel.offersResume(edited, pending: false, topicHasLocalRun: false, now: soon))
        var untimed = entry
        untimed.timing = nil
        #expect(!EntryTimingModel.offersResume(untimed, pending: false, topicHasLocalRun: false, now: soon))
    }

    /// A typed lap's badge is its type's label in the version, else its key; none on a step or an
    /// untyped lap.
    @Test func lapTypeBadges() {
        let laps: [TopicTimer.LapType] = [.init(key: "run", label: "Run")]
        let badges = Self.typed.segments.map { EntryTimingModel.lapTypeBadge($0, lapTypes: laps) }
        #expect(badges == [nil, "Run", "rest", nil])
    }
}
