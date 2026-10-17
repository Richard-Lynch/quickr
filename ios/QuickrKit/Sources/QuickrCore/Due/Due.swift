import Foundation

/// Due-status computation for topic schedules: a port of `backend/app/services/schedule.py`,
/// checked against `shared/fixtures/due-vectors.json`. Pure: no clock, no store.
///
/// **Daily.** A *slot* is each configured local time on each allowed ISO weekday, in the schedule's
/// timezone, as a UTC instant (see `ZoneClock` for gaps and folds). Let `s` be the latest slot in
/// `[scheduleSince, now]` and `p` the slot before it (which may be before `scheduleSince`). `s` is
/// satisfied by an entry at or after `s - min(2 h, (s - p) / 2)`; otherwise the topic is due since
/// `s`. `nextDueAt` is the first slot after `now` not already satisfied by an early entry; it
/// ignores `scheduleSince`, like the server.
///
/// **Interval.** Due `everyMinutes` after `max(lastEntryAt, scheduleSince)` (`scheduleSince` when
/// never logged).
///
/// Archived topics are never due. The server stays authoritative after each sync; this port lets
/// the app, widgets and notification extension recompute due state between syncs.
public enum Due {
    /// The longest early window: an entry this long before a slot satisfies it.
    public static let earlyWindowMax: TimeInterval = 2 * 3600
    /// Slots are searched in `[now - lookbackDays, now + lookaheadDays]`. Far enough back to find the
    /// slot before the latest one for a once-a-week schedule.
    public static let lookbackDays = 16
    public static let lookaheadDays = 9

    /// The due status of a scheduled topic at `now` (the server's `compute_due`).
    ///
    /// `scheduleSince` is when the schedule was (last) set: nothing before it can make the topic
    /// due. A timezone this OS does not know is treated as UTC (see `usesUTCFallback`).
    public static func status(
        of schedule: Schedule, now: Date, lastEntryAt: Date?, scheduleSince: Date, archived: Bool = false
    ) -> DueStatus {
        if archived { return DueStatus(isDue: false, lastEntryAt: lastEntryAt) }
        switch schedule {
        case .daily(let daily):
            return dailyStatus(daily, now: now, lastEntryAt: lastEntryAt, since: scheduleSince)
        case .interval(let interval):
            return intervalStatus(interval, now: now, lastEntryAt: lastEntryAt, since: scheduleSince)
        }
    }

    /// Every slot instant in `[start, end]`, ascending and de-duplicated (the server's `daily_slots`).
    public static func slots(of schedule: Schedule.Daily, from start: Date, through end: Date) -> [Date] {
        slotSeconds(schedule, from: start.timeIntervalSince1970, through: end.timeIntervalSince1970)
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// The most slots `upcomingSlots` returns (and `timeline` points it adds) in one call.
    public static let maxUpcomingSlots = 1_000
    /// How far ahead `upcomingSlots` looks before giving up.
    public static let upcomingHorizonDays = 3_660

    /// The next `count` slots strictly after `now`, ascending, for widget timelines and local
    /// reminders. `count` is clamped to `maxUpcomingSlots`. Unlike `status`, this is not bounded
    /// by the lookahead, only by `upcomingHorizonDays`; it returns fewer slots only when the
    /// horizon runs out (for example a schedule with no valid times or days).
    public static func upcomingSlots(of schedule: Schedule.Daily, after now: Date, count: Int) -> [Date] {
        let limit = min(count, maxUpcomingSlots)
        guard limit > 0, !schedule.times.isEmpty, schedule.days.contains(where: { (1...7).contains($0) }) else {
            return []
        }
        // Week-long windows, each searched like `slots` (so gaps and merges match), until enough.
        let week = TimeInterval(7 * ZoneClock.secondsPerDay)
        let start = now.timeIntervalSince1970
        let horizon = start + TimeInterval(upcomingHorizonDays * ZoneClock.secondsPerDay)
        var found: [Int] = []
        found.reserveCapacity(limit)
        var lower = start
        while found.count < limit, lower < horizon {
            let upper = min(lower + week, horizon)
            for slot in slotSeconds(schedule, from: lower, through: upper) where TimeInterval(slot) > lower {
                found.append(slot)
                if found.count == limit { break }
            }
            lower = upper
        }
        return found.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Whether `status`, `slots` and `message` read this timezone as UTC because the OS does not
    /// know it. The server validates zones, so this only happens when the device's tzdata lacks a
    /// newly added zone; the UI can use it to warn that reminder times may be off.
    public static func usesUTCFallback(timezone: String) -> Bool { ZoneClock(identifier: timezone) == nil }

    /// `usesUTCFallback(timezone:)` for a schedule's timezone.
    public static func usesUTCFallback(_ schedule: Schedule) -> Bool { usesUTCFallback(timezone: schedule.timezone) }

    /// The instants after `now` at which `status` may change if nothing is logged meanwhile, with
    /// the status from each. The first element is the status at `now` itself. A widget timeline
    /// can use the dates as entry dates directly.
    ///
    /// Daily: one point per upcoming slot (`count` of them, at most `maxUpcomingSlots`). Interval: the due instant, if it is
    /// still ahead. Archived: just `now`.
    public static func timeline(
        of schedule: Schedule, now: Date, lastEntryAt: Date?, scheduleSince: Date, archived: Bool = false,
        count: Int
    ) -> [(date: Date, status: DueStatus)] {
        func at(_ date: Date) -> DueStatus {
            status(of: schedule, now: date, lastEntryAt: lastEntryAt, scheduleSince: scheduleSince, archived: archived)
        }
        let current = at(now)
        var points = [(date: now, status: current)]
        guard !archived else { return points }
        switch schedule {
        case .daily(let daily):
            for slot in upcomingSlots(of: daily, after: now, count: count) { points.append((slot, at(slot))) }
        case .interval:
            if let dueAt = current.nextDueAt, dueAt > now { points.append((dueAt, at(dueAt))) }
        }
        return points
    }

    // MARK: - Daily

    private static func dailyStatus(_ schedule: Schedule.Daily, now: Date, lastEntryAt: Date?, since: Date)
        -> DueStatus
    {
        let nowSeconds = now.timeIntervalSince1970
        let day = TimeInterval(ZoneClock.secondsPerDay)
        let slots = slotSeconds(
            schedule, from: nowSeconds - TimeInterval(lookbackDays) * day,
            through: nowSeconds + TimeInterval(lookaheadDays) * day)
        let last = lastEntryAt?.timeIntervalSince1970

        // The first upcoming slot not already covered by an (early) entry.
        var nextDue: Date?
        if let first = slots.firstIndex(where: { TimeInterval($0) > nowSeconds }) {
            for index in first..<slots.count where !isSatisfied(slots, index, by: last) {
                nextDue = Date(timeIntervalSince1970: TimeInterval(slots[index]))
                break
            }
        }

        // The latest slot in [since, now]. Slots before the schedule took effect never make it due.
        let sinceSeconds = since.timeIntervalSince1970
        guard let latest = slots.lastIndex(where: { TimeInterval($0) <= nowSeconds }),
            TimeInterval(slots[latest]) >= sinceSeconds
        else { return DueStatus(isDue: false, nextDueAt: nextDue, lastEntryAt: lastEntryAt) }
        if isSatisfied(slots, latest, by: last) {
            return DueStatus(isDue: false, nextDueAt: nextDue, lastEntryAt: lastEntryAt)
        }
        return DueStatus(
            isDue: true, dueSince: Date(timeIntervalSince1970: TimeInterval(slots[latest])), nextDueAt: nextDue,
            lastEntryAt: lastEntryAt)
    }

    /// Whether an entry at `last` (the latest one) satisfies `slots[index]`: at or after the slot
    /// minus the early window, which is half the gap to the previous slot, capped at 2 h.
    private static func isSatisfied(_ slots: [Int], _ index: Int, by last: TimeInterval?) -> Bool {
        guard let last else { return false }
        let slot = TimeInterval(slots[index])
        let window = index > 0 ? min(earlyWindowMax, (slot - TimeInterval(slots[index - 1])) / 2) : earlyWindowMax
        return last >= slot - window
    }

    /// Slot instants (whole seconds since the epoch) in `[start, end]`, ascending, de-duplicated.
    ///
    /// Days run over the local dates from the day before `start`'s to the day after `end`'s, and the
    /// weekday filter uses that local date, before any gap shift. Sorting is by instant, because a
    /// gap can move a slot past a later time on the same day (or merge two slots into one).
    private static func slotSeconds(_ schedule: Schedule.Daily, from start: TimeInterval, through end: TimeInterval)
        -> [Int]
    {
        guard start <= end else { return [] }
        let clock = ZoneClock(identifier: schedule.timezone) ?? ZoneClock.utc
        let days = Set(schedule.days)
        let times = schedule.times.map { $0.hour * 3600 + $0.minute * 60 }
        let first = clock.epochDay(at: Int(start.rounded(.down))) - 1
        let last = clock.epochDay(at: Int(end.rounded(.up))) + 1
        var slots: [Int] = []
        slots.reserveCapacity((last - first + 1) * times.count)
        for day in first...last where days.contains(CivilTime.isoWeekday(epochDay: day)) {
            for time in times {
                let instant = clock.instant(epochDay: day, secondOfDay: time)
                if start <= TimeInterval(instant) && TimeInterval(instant) <= end { slots.append(instant) }
            }
        }
        slots.sort()
        var unique: [Int] = []
        unique.reserveCapacity(slots.count)
        for slot in slots where slot != unique.last { unique.append(slot) }
        return unique
    }

    // MARK: - Interval

    private static func intervalStatus(_ schedule: Schedule.Interval, now: Date, lastEntryAt: Date?, since: Date)
        -> DueStatus
    {
        // Counted from the latest entry, but never from before the schedule took effect.
        let base = lastEntryAt.map { max($0, since) } ?? since
        let dueAt = base.addingTimeInterval(TimeInterval(schedule.everyMinutes) * 60)
        let isDue = now >= dueAt
        return DueStatus(isDue: isDue, dueSince: isDue ? dueAt : nil, nextDueAt: dueAt, lastEntryAt: lastEntryAt)
    }
}

extension ZoneClock {
    static let utc = ZoneClock(identifier: "UTC")!
}
