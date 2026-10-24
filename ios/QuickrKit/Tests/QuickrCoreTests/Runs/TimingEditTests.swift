import Foundation
import QuickrCore
import Testing

/// The Edit times model (timers.md §3.8): the server's T2–T5 rules client-side, and the edit a
/// save sends (the PWA's `timingEdit.test.ts`).
@Suite struct TimingEditTests {
    static let steps: [TopicTimer.Step] = [
        .init(key: "shower", label: "Shower"), .init(key: "dress", label: "Dress"),
        .init(key: "coffee", label: "Coffee"),
    ]
    static let utc = TimingEditClock(timeZone: TimeZone(identifier: "UTC")!)

    static func ms(_ hms: String) -> Int { RunInstant.parse("2026-10-23T\(hms)Z")! }

    static func seg(_ kind: RunSegmentKind, _ step: String?, _ label: String, _ from: String, _ to: String, paused: Int)
        -> RunSegment
    {
        RunSegment(
            kind: kind, step: step, label: label, startedAt: ms(from), endedAt: ms(to),
            activeMs: ms(to) - ms(from) - paused, pausedMs: paused)
    }

    /// Shower 0:00–4:00.250 (paused 1:00–1:30), a lap to 5:00, Dress to 9:00; Coffee skipped.
    static let timing = Timing(
        startedAt: ms("07:00:00.000"), endedAt: ms("07:09:00.000"), activeMs: 510_000, pausedMs: 30_000,
        complete: false, edited: false,
        segments: [
            seg(.step, "shower", "Shower", "07:00:00.000", "07:04:00.250", paused: 30_000),
            seg(.lap, nil, "Lap 1", "07:04:00.250", "07:05:00.000", paused: 0),
            seg(.step, "dress", "Dress", "07:05:00.000", "07:09:00.000", paused: 0),
        ],
        skipped: ["coffee"], pauses: [RunPause(start: ms("07:01:00.000"), end: ms("07:01:30.000"))])

    /// Well after the run, so the 24-hour bound only bites where a test means it to.
    static let now = RunInstant.parse("2026-12-01T00:00:00Z")!

    static func draft(_ timing: Timing = timing) -> TimingDraft { TimingDraft(timing: timing, clock: utc) }
    static func at(_ hms: String) -> String { utc.text(ms("\(hms).000")) }
    static func check(_ d: TimingDraft, now: Int = now) -> TimingDraft.Checked { d.check(steps: steps, now: now) }

    @Test func roundTripsLocalTextToTheSecond() {
        let ms = Self.ms("07:04:05.000")
        let text = Self.utc.text(ms)
        #expect(text == "2026-10-23 07:04:05")
        let back = Self.utc.milliseconds(text)
        #expect(back == ms)
        let withT = Self.utc.milliseconds("2026-10-23T07:04")
        #expect(withT == Self.ms("07:04:00.000"))
        #expect(Self.utc.milliseconds("nope") == nil)
        #expect(Self.utc.milliseconds("2026-04-31 07:00:00") == nil, "a day April doesn't have")
    }

    @Test func anUntouchedDraftSendsTheExactInstants() throws {
        let r = Self.check(Self.draft())
        #expect(r.errors.isEmpty)
        let edit = try #require(r.edit)
        #expect(edit.startedAt == Self.ms("07:00:00.000"))
        let ends = edit.segments.map(\.endedAt)
        #expect(ends == [Self.ms("07:04:00.250"), Self.ms("07:05:00.000"), Self.ms("07:09:00.000")])
        let kinds = edit.segments.map(\.kind)
        #expect(kinds == [.step, .lap, .step])
        let stepKeys = edit.segments.map(\.step)
        #expect(stepKeys == ["shower", nil, "dress"])
        #expect(edit.skipped == ["coffee"])
        #expect(edit.pauses == Self.timing.pauses)
        #expect(r.activeMs == Self.timing.activeMs)
        #expect(r.pausedMs == 30_000)
        let labels = r.segments.map(\.label)
        #expect(labels == ["Shower", "Lap 1", "Dress"])
        let active = r.segments.map(\.activeMs)
        #expect(active == [210_250, 59_750, 240_000])
        // The server's rebuild of it is the run's own timing, edited.
        var expected = Self.timing
        expected.edited = true
        let rebuilt = edit.timing(steps: Self.steps)
        #expect(rebuilt == expected)
    }

    @Test func anEditedEndMovesTheNextStartAndTheTotals() {
        var d = Self.draft()
        d.segments[0].endedAt = Self.at("07:03:00")
        let r = Self.check(d)
        let end = r.edit?.segments[0].endedAt
        #expect(end == Self.ms("07:03:00.000"))
        let active = r.segments.map(\.activeMs)
        #expect(active == [150_000, 120_000, 240_000])
        #expect(r.activeMs == 510_000)
    }

    @Test func refusesASegmentEndingBeforeItStarts() {
        var d = Self.draft()
        d.segments[2].endedAt = Self.at("07:04:30")
        let r = Self.check(d)
        #expect(r.errors == ["segments.2.ended_at": "Before the segment’s start"])
        #expect(r.edit == nil)
    }

    @Test func refusesAStepTwiceOrTimedAndSkippedOrNotOfTheVersion() {
        var twice = Self.draft()
        twice.setSegmentStep(1, "shower")
        #expect(Self.check(twice).errors == ["segments.1.step": "Step 'Shower' appears more than once"])
        var d = Self.draft()
        d.skipped = ["coffee", "dress"]
        #expect(Self.check(d).errors == ["skipped.1": "Step 'Dress' appears more than once"])
        var gone = Self.draft()
        gone.segments[0].step = "bath"
        #expect(Self.check(gone).errors == ["segments.0.step": "'bath' is not a step of the run's version"])
    }

    @Test func timingASkippedStepTakesItOffTheSkippedList() {
        var d = Self.draft()
        d.setSegmentStep(1, "coffee")
        #expect(d.skipped.isEmpty)
        let step = Self.check(d).edit?.segments[1].step
        #expect(step == "coffee")
    }

    @Test func refusesPausesOutOfOrderReversedOrOutsideTheRun() {
        var before = Self.draft()
        before.pauses = [.init(start: Self.at("06:59:00"), end: Self.at("07:01:00"))]
        #expect(Self.check(before).errors == ["pauses.0.start": "Before the run’s start or the previous pause’s end"])
        var reversed = Self.draft()
        reversed.pauses = [.init(start: Self.at("07:02:00"), end: Self.at("07:01:00"))]
        #expect(Self.check(reversed).errors == ["pauses.0.end": "Before the pause’s start"])
        var after = Self.draft()
        after.pauses = [.init(start: Self.at("07:08:00"), end: Self.at("07:10:00"))]
        #expect(Self.check(after).errors == ["pauses.0.end": "After the run’s end"])
        var overlap = Self.draft()
        overlap.pauses = [
            .init(start: Self.at("07:01:00"), end: Self.at("07:03:00")),
            .init(start: Self.at("07:02:00"), end: Self.at("07:04:00")),
        ]
        let keys = Array(Self.check(overlap).errors.keys)
        #expect(keys == ["pauses.1.start"])
    }

    @Test func refusesALongRunAnEmptyRunAndUnparsableTimes() {
        var long = Self.draft()
        long.segments[2].endedAt = Self.utc.text(RunInstant.parse("2026-10-31T07:00:00Z")!)
        #expect(Self.check(long).errors == ["segments.2.ended_at": "More than 7 days after the start"])
        var empty = Self.draft()
        empty.segments = []
        empty.pauses = []
        #expect(Self.check(empty).errors == ["segments": "Keep at least one segment"])
        var blank = Self.draft()
        blank.startedAt = ""
        let error = Self.check(blank).errors["started_at"]
        #expect(error == "Enter a date and time")
    }

    @Test func aNewSegmentTimesTheFirstUnusedStepElseALap() {
        var noSkips = Self.timing
        noSkips.skipped = []
        var d = Self.draft(noSkips)
        d.addSegment(steps: Self.steps)
        let first = d.segments[3]
        let firstKind: RunSegmentKind = first.kind
        let firstStep: String? = first.step
        #expect(firstKind == .step)
        #expect(firstStep == "coffee")
        #expect(first.endedAt == Self.at("07:09:00"))
        d.addSegment(steps: Self.steps)
        let second = d.segments[4]
        let secondKind: RunSegmentKind = second.kind
        let secondStep: String? = second.step
        #expect(secondKind == .lap)
        #expect(secondStep == nil)
        d.setSegmentStep(0, nil)
        let labels = Self.check(d).segments.map(\.label)
        #expect(labels == ["Lap 1", "Lap 2", "Dress", "Coffee", "Lap 3"])
    }

    @Test func aNewSegmentOrPauseCopiesTheRunEndsExactMillisecond() {
        var odd = Self.timing
        odd.endedAt = Self.ms("07:09:00.750")
        odd.segments[2] = Self.seg(.step, "dress", "Dress", "07:05:00.000", "07:09:00.750", paused: 0)
        var d = Self.draft(odd)
        d.addSegment(steps: Self.steps)
        d.addPause()
        let r = Self.check(d)
        #expect(r.errors.isEmpty)
        let end = r.edit?.segments[3].endedAt
        #expect(end == Self.ms("07:09:00.750"))
        let pause = r.edit?.pauses[1]
        #expect(pause == RunPause(start: Self.ms("07:09:00.750"), end: Self.ms("07:09:00.750")))
    }

    @Test func untouchedFieldsInTheSameSecondKeepTheirOwnMilliseconds() {
        let close = Timing(
            startedAt: Self.ms("07:00:01.100"), endedAt: Self.ms("07:00:01.900"), activeMs: 800, pausedMs: 0,
            complete: false, edited: false,
            segments: [Self.seg(.step, "shower", "Shower", "07:00:01.100", "07:00:01.900", paused: 0)], skipped: [],
            pauses: [])
        var d = Self.draft(close)
        #expect(d.startedAt == d.segments[0].endedAt)
        let edit = Self.check(d).edit
        let started: Int? = edit?.startedAt
        let ended: Int? = edit?.segments.first?.endedAt
        #expect(started == Self.ms("07:00:01.100"))
        #expect(ended == Self.ms("07:00:01.900"))
        // Edited, then set back to the same text: the field's own original again.
        let text = d.startedAt
        d.startedAt = Self.at("07:00:00")
        d.startedAt = text
        let again = Self.check(d).edit?.startedAt
        #expect(again == Self.ms("07:00:01.100"))
    }

    @Test func acceptsAZeroLengthSegmentExactlySevenDaysAndAPauseAtTheStart() {
        var zero = Self.draft()
        zero.segments[0].endedAt = Self.at("07:04:30")
        zero.segments[1].endedAt = Self.at("07:04:30")
        #expect(Self.check(zero).errors.isEmpty)
        let lap = Self.check(zero).segments[1].activeMs
        #expect(lap == 0)

        var week = Self.draft()
        week.segments[2].endedAt = Self.utc.text(RunInstant.parse("2026-10-30T07:00:00Z")!)
        #expect(Self.check(week).errors.isEmpty)
        week.segments[2].endedAt = Self.utc.text(RunInstant.parse("2026-10-30T07:00:01Z")!)
        #expect(Self.check(week).errors == ["segments.2.ended_at": "More than 7 days after the start"])

        var atStart = Self.draft()
        atStart.pauses = [.init(start: atStart.startedAt, end: Self.at("07:00:30"))]
        #expect(Self.check(atStart).errors.isEmpty)
        atStart.pauses.append(.init(start: Self.at("07:00:30"), end: Self.at("07:01:00")))
        #expect(Self.check(atStart).errors.isEmpty)
    }

    @Test func checksTheCapturedAtBoundsOnEveryInstant() {
        var early = Self.draft()
        early.startedAt = "1999-12-31 12:00:00"
        let error = Self.check(early).errors["started_at"]
        #expect(error == "Must not be before 2000-01-01")
        let d = Self.draft()
        let now = Self.ms("07:00:00.000")
        #expect(Self.check(d, now: now).errors.isEmpty)
        var late = Self.draft()
        late.pauses = [.init(start: Self.at("07:08:00"), end: Self.at("07:08:30"))]
        let errors = Self.check(late, now: now - 24 * 3_600_000 + 8 * 60_000).errors
        #expect(
            errors == [
                "segments.2.ended_at": "Must not be more than 24 hours in the future",
                "pauses.0.end": "Must not be more than 24 hours in the future",
            ])
    }

    @Test func mapsTheServersFieldPathsOntoTheForms() {
        #expect(TimingDraft.field(forServerPath: "timing.segments.1.ended_at") == "segments.1.ended_at")
        #expect(TimingDraft.field(forServerPath: "timing") == "")
        #expect(TimingDraft.field(forServerPath: "captured_at") == nil)
    }

    @Test func notesATimeThatHappensTwiceAndOneThatIsSkipped() {
        // Clocks went back at 02:00 BST on 2026-10-25, and forward at 01:00 GMT on 2026-03-29.
        let d = TimingDraft(
            timing: Self.timing, clock: TimingEditClock(timeZone: TimeZone(identifier: "Europe/London")!))
        #expect(
            d.localTimeNote("2026-10-25 01:30:00")
                == "01:30:00 happens twice that day (the clocks went back): the earlier one is used.")
        #expect(
            d.localTimeNote("2026-03-29T01:30")
                == "There is no 01:30:00 that day (the clocks went forward): it reads as 02:30:00.")
        #expect(d.localTimeNote("2026-10-24 01:30:00") == nil)
        #expect(d.localTimeNote("") == nil)
    }
}
