import Foundation
import QuickrCore
import Testing

/// Every case in `shared/fixtures/due-vectors.json`, generated from the real `schedule.py`.
@Suite struct DueVectorTests {
    static let vectors = DueVectors.shared

    @Test func vectorCountsAndConstantsMatchTheGenerator() {
        let vectors = Self.vectors
        #expect(vectors.due.count == vectors.counts["due"])
        #expect(vectors.slots.count == vectors.counts["slots"])
        #expect(vectors.messages.count == vectors.counts["messages"])
        #expect(vectors.due.count == 1831 && vectors.slots.count == 63 && vectors.messages.count == 360)
        #expect(Due.earlyWindowMax == TimeInterval(vectors.earlyWindowMaxSeconds))
        #expect(Due.lookbackDays == vectors.lookbackDays)
        #expect(Due.lookaheadDays == vectors.lookaheadDays)
    }

    @Test(arguments: vectors.due)
    func due(_ vector: DueVectors.DueCase) {
        let status = Due.status(
            of: vector.schedule, now: vector.now, lastEntryAt: vector.lastEntryAt, scheduleSince: vector.scheduleSince,
            archived: vector.archived)
        #expect(status == vector.expected)
    }

    @Test(arguments: vectors.slots)
    func slots(_ vector: DueVectors.SlotCase) {
        #expect(Due.slots(of: vector.schedule, from: vector.start, through: vector.end) == vector.expected)
    }

    @Test(arguments: vectors.messages)
    func message(_ vector: DueVectors.MessageCase) {
        #expect(Due.message(timezone: vector.timezone, dueSince: vector.dueSince, now: vector.now) == vector.expected)
    }
}

/// The surprises found while generating the vectors (docs/ios/STATUS.md), pinned on their own.
/// Expected values come from the backend's `schedule.py`.
@Suite struct DueSemanticsTests {
    static let since = utc("2026-01-01T00:00:00Z")

    static func utc(_ text: String) -> Date { try! DueVectors.date(text) }

    static func daily(_ times: [String], _ timezone: String, days: [Int] = Schedule.Daily.everyDay) -> Schedule.Daily {
        Schedule.Daily(times: times.map { TimeOfDay($0)! }, days: days, timezone: timezone)
    }

    @Test func aGapTimeLandsAfterTheGapShiftedByItsLength() {
        // London springs forward 01:00 → 02:00 local; 01:30 uses GMT, i.e. 02:30 BST.
        let slots = Due.slots(
            of: Self.daily(["01:30"], "Europe/London"), from: Self.utc("2026-03-29T00:00:00Z"),
            through: Self.utc("2026-03-29T03:00:00Z"))
        #expect(slots == [Self.utc("2026-03-29T01:30:00Z")])
    }

    @Test func anAmbiguousTimeTakesItsFirstOccurrence() {
        // New York falls back 02:00 EDT → 01:00 EST; 01:30 happens at 05:30Z and again at 06:30Z.
        let slots = Due.slots(
            of: Self.daily(["01:30"], "America/New_York"), from: Self.utc("2026-11-01T00:00:00Z"),
            through: Self.utc("2026-11-01T12:00:00Z"))
        #expect(slots == [Self.utc("2026-11-01T05:30:00Z")])
    }

    @Test func aGapCanMergeTwoSlots() {
        // 01:30 (in the gap) and 02:30 BST are the same instant.
        let slots = Due.slots(
            of: Self.daily(["01:30", "02:30"], "Europe/London"), from: Self.utc("2026-03-29T00:00:00Z"),
            through: Self.utc("2026-03-29T03:00:00Z"))
        #expect(slots == [Self.utc("2026-03-29T01:30:00Z")])
    }

    @Test func slotsAreOrderedByInstantNotByWallTime() {
        // 01:30 is shifted past 02:15 BST (01:15Z).
        let slots = Due.slots(
            of: Self.daily(["01:30", "02:15"], "Europe/London"), from: Self.utc("2026-03-29T00:00:00Z"),
            through: Self.utc("2026-03-29T03:00:00Z"))
        #expect(slots == [Self.utc("2026-03-29T01:15:00Z"), Self.utc("2026-03-29T01:30:00Z")])
    }

    @Test func theEarlyWindowIsHalfTheGapToThePreviousSlot() {
        // Slots 01:15Z and 01:30Z: the window before 01:30Z is only 7.5 minutes.
        let schedule = Schedule.daily(Self.daily(["01:30", "02:15"], "Europe/London"))
        let now = Self.utc("2026-03-29T01:40:00Z")
        let inside = Due.status(
            of: schedule, now: now, lastEntryAt: Self.utc("2026-03-29T01:22:30Z"), scheduleSince: Self.since)
        #expect(!inside.isDue && inside.nextDueAt == Self.utc("2026-03-30T00:30:00Z"))
        let outside = Due.status(
            of: schedule, now: now, lastEntryAt: Self.utc("2026-03-29T01:22:29Z"), scheduleSince: Self.since)
        #expect(outside.isDue && outside.dueSince == Self.utc("2026-03-29T01:30:00Z"))
    }

    @Test func nextDueAtIgnoresScheduleSince() {
        let schedule = Schedule.daily(Self.daily(["08:00"], "UTC"))
        let now = Self.utc("2026-03-10T12:00:00Z")
        let notYet = Due.status(
            of: schedule, now: now, lastEntryAt: nil, scheduleSince: Self.utc("2026-03-11T00:00:00Z"))
        #expect(notYet == DueStatus(isDue: false, nextDueAt: Self.utc("2026-03-11T08:00:00Z")))
        // A slot exactly at schedule_since counts.
        let atSince = Due.status(
            of: schedule, now: now, lastEntryAt: nil, scheduleSince: Self.utc("2026-03-10T08:00:00Z"))
        #expect(atSince.isDue && atSince.dueSince == Self.utc("2026-03-10T08:00:00Z"))
    }

    @Test func weekdaysFilterOnTheLocalDateBeforeTheGapShift() {
        // Nuuk springs forward at Saturday 23:00 → Sunday 00:00. Saturday's 23:30 is in the gap and
        // lands on Sunday 00:30 local, but it is still Saturday's slot.
        let range = (Self.utc("2026-03-27T00:00:00Z"), Self.utc("2026-03-31T00:00:00Z"))
        let saturday = Due.slots(of: Self.daily(["23:30"], "America/Nuuk", days: [6]), from: range.0, through: range.1)
        #expect(saturday == [Self.utc("2026-03-29T01:30:00Z")])
        let sunday = Due.slots(of: Self.daily(["23:30"], "America/Nuuk", days: [7]), from: range.0, through: range.1)
        #expect(sunday == [Self.utc("2026-03-30T00:30:00Z")])
    }

    @Test func messagesUseCLocaleNamesAndExactlyThirtyMinutesIsOverdue() {
        let since = Self.utc("2026-03-10T08:00:00Z")
        func message(_ now: String, _ timezone: String = "Europe/London") -> String {
            Due.message(timezone: timezone, dueSince: since, now: Self.utc(now))
        }
        #expect(message("2026-03-10T08:29:59Z") == "Time to log")
        #expect(message("2026-03-10T08:30:00Z") == "Overdue since 08:00")
        #expect(message("2026-03-16T23:59:00Z") == "Overdue since Tue 08:00")
        #expect(message("2026-03-17T00:00:00Z") == "Overdue since 10 Mar")
        // Kathmandu is UTC+05:45: 18:00Z is Tuesday 23:45 local, and the next morning is another day.
        let kathmandu = Due.message(
            timezone: "Asia/Kathmandu", dueSince: Self.utc("2026-03-10T18:00:00Z"),
            now: Self.utc("2026-03-11T03:00:00Z"))
        #expect(kathmandu == "Overdue since Tue 23:45")
        // A due_since in the future is still "Time to log" (negative age).
        #expect(message("2026-03-10T07:00:00Z") == "Time to log")
    }

    @Test func intervalCountsFromTheLaterOfEntryAndSince() {
        let schedule = Schedule.interval(.init(everyMinutes: 60, timezone: "UTC"))
        let since = Self.utc("2026-03-10T10:00:00Z")
        let old = Due.status(
            of: schedule, now: Self.utc("2026-03-10T10:30:00Z"), lastEntryAt: Self.utc("2026-03-10T08:00:00Z"),
            scheduleSince: since)
        #expect(old.nextDueAt == Self.utc("2026-03-10T11:00:00Z") && !old.isDue)
        let due = Due.status(
            of: schedule, now: Self.utc("2026-03-10T11:00:00Z"), lastEntryAt: nil, scheduleSince: since)
        #expect(due.isDue && due.dueSince == Self.utc("2026-03-10T11:00:00Z"))
    }

    @Test func archivedIsNeverDueButKeepsTheLastEntry() {
        let last = Self.utc("2026-03-01T00:00:00Z")
        let status = Due.status(
            of: .daily(Self.daily(["08:00"], "UTC")), now: Self.utc("2026-03-10T12:00:00Z"), lastEntryAt: last,
            scheduleSince: Self.since, archived: true)
        #expect(status == DueStatus(isDue: false, lastEntryAt: last))
    }

    @Test func anUnknownTimezoneReadsAsUTC() {
        let range = (Self.utc("2026-03-10T00:00:00Z"), Self.utc("2026-03-11T00:00:00Z"))
        #expect(
            Due.slots(of: Self.daily(["08:00"], "Not/AZone"), from: range.0, through: range.1)
                == Due.slots(of: Self.daily(["08:00"], "UTC"), from: range.0, through: range.1))
        #expect(Due.usesUTCFallback(timezone: "Not/AZone"))
        #expect(!Due.usesUTCFallback(.daily(Self.daily(["08:00"], "Asia/Kathmandu"))))
        #expect(!Due.usesUTCFallback(timezone: "UTC"))
    }
}

/// Transitions outside the 2026 vector grid, and sub-second edges. Expected values come from the
/// backend's `schedule.py` (zoneinfo, `fold=0`).
@Suite struct DueRegressionTests {
    static func utc(_ text: String) -> Date { DueSemanticsTests.utc(text) }

    static func daily(_ times: [String], _ timezone: String, days: [Int] = Schedule.Daily.everyDay) -> Schedule.Daily {
        DueSemanticsTests.daily(times, timezone, days: days)
    }

    @Test func kathmandu1986OffsetChangeUsesTheOldOffsetInTheGap() {
        // +05:30 → +05:45 at 1986-01-01 00:00 local: 00:00–00:15 does not exist.
        let slots = Due.slots(
            of: Self.daily(["00:00", "00:10", "08:00"], "Asia/Kathmandu"), from: Self.utc("1985-12-31T12:00:00Z"),
            through: Self.utc("1986-01-01T12:00:00Z"))
        #expect(
            slots == [
                Self.utc("1985-12-31T18:30:00Z"), Self.utc("1985-12-31T18:40:00Z"), Self.utc("1986-01-01T02:15:00Z"),
            ])
    }

    @Test func apiaSkippedDayMergesIntoTheNextOne() {
        // Samoa jumped from 2011-12-29 (UTC-10) straight to 2011-12-31 (UTC+14). The skipped 30th's
        // 08:00 uses the old offset, which is the same instant as the 31st's 08:00.
        let range = (Self.utc("2011-12-28T00:00:00Z"), Self.utc("2012-01-01T00:00:00Z"))
        #expect(
            Due.slots(of: Self.daily(["08:00"], "Pacific/Apia"), from: range.0, through: range.1) == [
                Self.utc("2011-12-28T18:00:00Z"), Self.utc("2011-12-29T18:00:00Z"), Self.utc("2011-12-30T18:00:00Z"),
                Self.utc("2011-12-31T18:00:00Z"),
            ])
        // A Friday-only schedule still has a slot on the skipped Friday.
        let fridays = Due.slots(
            of: Self.daily(["08:00"], "Pacific/Apia", days: [5]), from: Self.utc("2011-12-20T00:00:00Z"),
            through: Self.utc("2012-01-10T00:00:00Z"))
        #expect(
            fridays == [
                Self.utc("2011-12-23T18:00:00Z"), Self.utc("2011-12-30T18:00:00Z"), Self.utc("2012-01-05T18:00:00Z"),
            ])
    }

    @Test func fractionalSecondsAroundSlotsAndTheEarlyWindow() {
        // Slots 08:00 and 09:00 UTC: the window before 09:00 is 30 minutes.
        let schedule = Schedule.daily(Self.daily(["08:00", "09:00"], "UTC"))
        let since = Self.utc("2026-01-01T00:00:00Z")
        let nine = Self.utc("2026-03-10T09:00:00Z")
        func status(_ now: Date, _ last: Date? = nil) -> DueStatus {
            Due.status(of: schedule, now: now, lastEntryAt: last, scheduleSince: since)
        }
        let justBefore = status(nine - 0.001)
        #expect(justBefore.dueSince == Self.utc("2026-03-10T08:00:00Z") && justBefore.nextDueAt == nine)
        let atSlot = status(nine)
        #expect(atSlot.dueSince == nine && atSlot.nextDueAt == Self.utc("2026-03-11T08:00:00Z"))

        let now = nine + 0.5
        let windowStart = Self.utc("2026-03-10T08:30:00Z")
        #expect(status(now, windowStart - 0.001).dueSince == nine)
        #expect(!status(now, windowStart).isDue)
        #expect(!status(now, windowStart + 0.001).isDue)

        // A slot exactly at schedule_since counts; a millisecond later it does not.
        let atSince = Due.status(of: schedule, now: now, lastEntryAt: nil, scheduleSince: nine)
        #expect(atSince.dueSince == nine)
        #expect(!Due.status(of: schedule, now: now, lastEntryAt: nil, scheduleSince: nine + 0.001).isDue)

        // An upcoming slot strictly after `now`, to the millisecond.
        let daily = Self.daily(["08:00", "09:00"], "UTC")
        #expect(Due.upcomingSlots(of: daily, after: nine - 0.001, count: 1) == [nine])
        #expect(Due.upcomingSlots(of: daily, after: nine, count: 1) == [Self.utc("2026-03-11T08:00:00Z")])

        let message = Due.message(
            timezone: "UTC", dueSince: Self.utc("2026-03-10T08:00:00Z"), now: windowStart - 0.001)
        #expect(message == "Time to log")
    }
}

@Suite struct DueTimelineTests {
    static func utc(_ text: String) -> Date { DueSemanticsTests.utc(text) }

    @Test func upcomingSlotsGoPastTheLookaheadAndSkipNow() {
        let weekly = Schedule.Daily(times: [TimeOfDay("09:00")!], days: [3], timezone: "Europe/London")
        let now = Self.utc("2026-03-18T09:00:00Z")  // a Wednesday slot: excluded, strictly after
        let slots = Due.upcomingSlots(of: weekly, after: now, count: 5)
        #expect(slots.count == 5)
        #expect(slots.first == Self.utc("2026-03-25T09:00:00Z"))
        // Across the spring-forward: 09:00 BST is 08:00Z.
        #expect(slots[1] == Self.utc("2026-04-01T08:00:00Z"))
        #expect(slots.last == Self.utc("2026-04-22T08:00:00Z"))
        #expect(Due.upcomingSlots(of: weekly, after: now, count: 0).isEmpty)
    }

    @Test func upcomingSlotsAreBounded() {
        let now = Self.utc("2026-03-10T00:00:00Z")
        let hourly = Schedule.Daily(
            times: (0..<24).map { TimeOfDay(hour: $0, minute: 0) }, timezone: "Europe/London")
        let many = Due.upcomingSlots(of: hourly, after: now, count: 1_000_000)
        #expect(many.count == Due.maxUpcomingSlots)
        #expect(zip(many, many.dropFirst()).allSatisfy { $0 < $1 })
        // No valid weekday: nothing, without walking the horizon.
        let never = Schedule.Daily(times: [TimeOfDay(hour: 8, minute: 0)], days: [0, 8], timezone: "UTC")
        #expect(Due.upcomingSlots(of: never, after: now, count: 10).isEmpty)
        // Chunked search agrees with one `slots` call, including across a DST gap.
        let multi = Schedule.Daily(
            times: ["00:00", "01:30", "02:15", "02:30", "23:59"].map { TimeOfDay($0)! }, timezone: "Europe/London")
        let start = Self.utc("2026-03-20T00:00:00Z")
        let expected = Due.slots(of: multi, from: start, through: Self.utc("2026-04-30T00:00:00Z"))
            .filter { $0 > start }
        #expect(Due.upcomingSlots(of: multi, after: start, count: expected.count) == expected)
    }

    @Test func dailyTimelineHasAPointPerSlot() {
        let schedule = Schedule.daily(.init(times: [TimeOfDay("08:00")!, TimeOfDay("20:00")!], timezone: "UTC"))
        let points = Due.timeline(
            of: schedule, now: Self.utc("2026-03-10T09:00:00Z"), lastEntryAt: Self.utc("2026-03-10T08:05:00Z"),
            scheduleSince: Self.utc("2026-01-01T00:00:00Z"), count: 3)
        #expect(
            points.map(\.date) == [
                Self.utc("2026-03-10T09:00:00Z"), Self.utc("2026-03-10T20:00:00Z"), Self.utc("2026-03-11T08:00:00Z"),
                Self.utc("2026-03-11T20:00:00Z"),
            ])
        #expect(points.map(\.status.isDue) == [false, true, true, true])
        #expect(points[2].status.dueSince == Self.utc("2026-03-11T08:00:00Z"))
    }

    @Test func intervalTimelineEndsAtTheDueInstant() {
        let schedule = Schedule.interval(.init(everyMinutes: 90, timezone: "UTC"))
        let since = Self.utc("2026-03-10T00:00:00Z")
        let points = Due.timeline(
            of: schedule, now: Self.utc("2026-03-10T09:00:00Z"), lastEntryAt: Self.utc("2026-03-10T08:00:00Z"),
            scheduleSince: since, count: 10)
        #expect(points.map(\.date) == [Self.utc("2026-03-10T09:00:00Z"), Self.utc("2026-03-10T09:30:00Z")])
        #expect(points.map(\.status.isDue) == [false, true])
        let archived = Due.timeline(
            of: schedule, now: Self.utc("2026-03-10T09:00:00Z"), lastEntryAt: nil, scheduleSince: since,
            archived: true, count: 10)
        #expect(archived.count == 1)
    }
}

@Suite struct DuePerformanceTests {
    /// Widget timelines and the badge recompute every topic often; one daily status must stay cheap.
    @Test func everyDueVectorComputesQuickly() {
        let vectors = DueVectors.shared.due
        let clock = ContinuousClock()
        var dueCount = 0
        let elapsed = clock.measure {
            for vector in vectors {
                let status = Due.status(
                    of: vector.schedule, now: vector.now, lastEntryAt: vector.lastEntryAt,
                    scheduleSince: vector.scheduleSince, archived: vector.archived)
                if status.isDue { dueCount += 1 }
            }
        }
        #expect(dueCount > 0)
        // About 1 ms per status would still be fine for a widget; a debug build does far better.
        #expect(elapsed < .seconds(2), "1,831 statuses took \(elapsed)")
        print("DuePerformanceTests: 1,831 statuses in \(elapsed)")
    }

    /// A due-list widget reload: 20 topics, a day of points each for a five-times-a-day schedule.
    @Test func widgetTimelinesComputeQuickly() {
        let schedule = Schedule.daily(
            .init(
                times: ["00:00", "01:30", "02:15", "02:30", "23:59"].map { TimeOfDay($0)! },
                timezone: "America/New_York"))
        let now = DueSemanticsTests.utc("2026-11-01T04:00:00Z")
        let clock = ContinuousClock()
        var points = 0
        let elapsed = clock.measure {
            for topic in 0..<20 {
                points +=
                    Due.timeline(
                        of: schedule, now: now, lastEntryAt: now - TimeInterval(topic * 600),
                        scheduleSince: DueSemanticsTests.since, count: 48
                    ).count
            }
        }
        #expect(points == 20 * 49)
        #expect(elapsed < .seconds(1), "20 timelines of 48 points took \(elapsed)")
        print("DuePerformanceTests: 20 widget timelines (48 points) in \(elapsed)")
    }
}
