import Foundation

/// Local wall time ↔ UTC instant in one IANA zone, with Python's PEP 495 `fold=0` semantics.
///
/// `TimeZone` is used for UTC offsets only. `Calendar`'s skipped/repeated-time policies are never
/// consulted, so the mapping is exactly the one `schedule.py` gets from `zoneinfo`:
/// - a nonexistent wall time (spring-forward gap) uses the offset in effect *before* the gap, so it
///   lands after the gap, shifted forward by the gap's length (London 01:30 on 2026-03-29 → 01:30Z);
/// - an ambiguous wall time (fall-back fold) uses its first occurrence (the pre-transition offset).
///
/// Days are counted from 1970-01-01 ("epoch days"), and wall times are seconds since local midnight
/// of that day, so no calendar object is needed anywhere.
struct ZoneClock: Sendable {
    static let secondsPerDay = 86_400

    let zone: TimeZone

    /// `nil` if the identifier is unknown to this OS's tzdata.
    init?(identifier: String) {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        self.zone = zone
    }

    func offset(at seconds: Int) -> Int {
        zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// The UTC instant (seconds since the epoch) of a local wall time.
    ///
    /// The wall time is read as if it were UTC (`wall`); the candidates are `wall - o` for the
    /// offsets `before` and `after` in effect a day either side. A candidate is valid if the zone
    /// really uses its offset there. `wall - before` valid → it (in a fold both are valid and this
    /// is the first occurrence); else `wall - after` valid → it; else (a gap) `wall - before`,
    /// which lands after the gap. Assumes at most one transition within a day of the wall time,
    /// which holds for every zone in current tzdata.
    func instant(epochDay: Int, secondOfDay: Int) -> Int {
        let wall = epochDay * Self.secondsPerDay + secondOfDay
        let before = offset(at: wall - Self.secondsPerDay)
        let preTransition = wall - before
        if offset(at: preTransition) == before { return preTransition }
        let after = offset(at: wall + Self.secondsPerDay)
        if after != before, offset(at: wall - after) == after { return wall - after }
        return preTransition
    }

    /// The local calendar day (epoch days) containing an instant.
    func epochDay(at seconds: Int) -> Int {
        (seconds + offset(at: seconds)).floorDiv(Self.secondsPerDay)
    }

    /// The local wall-clock fields of an instant.
    func civil(at seconds: Int) -> CivilTime {
        let local = seconds + offset(at: seconds)
        let day = local.floorDiv(Self.secondsPerDay)
        let secondOfDay = local - day * Self.secondsPerDay
        return CivilTime(epochDay: day, hour: secondOfDay / 3600, minute: secondOfDay % 3600 / 60)
    }
}

/// A local date and minute, plus the ISO weekday and Gregorian fields derived from the epoch day.
struct CivilTime: Sendable, Hashable {
    let epochDay: Int
    let hour: Int
    let minute: Int

    var isoWeekday: Int { Self.isoWeekday(epochDay: epochDay) }

    /// 1970-01-01 was a Thursday (ISO 4).
    static func isoWeekday(epochDay: Int) -> Int { (epochDay + 3).floorMod(7) + 1 }

    /// (year, month 1–12, day 1–31). Howard Hinnant's `civil_from_days`.
    var date: (year: Int, month: Int, day: Int) {
        let z = epochDay + 719_468
        let era = z.floorDiv(146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

extension Int {
    fileprivate func floorDiv(_ divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    fileprivate func floorMod(_ divisor: Int) -> Int { self - floorDiv(divisor) * divisor }
}
