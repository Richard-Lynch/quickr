import Foundation

/// Run instants as integer epoch milliseconds (timers.md §2.3).
///
/// Every instant in a run is a whole millisecond, so every duration is an exact integer difference
/// and segment sums equal the totals exactly. Wire strings are parsed here by hand, truncating
/// sub-millisecond digits, and never go through `Date` or a `Double`: the port of `parse_instant`
/// and `format_instant` in backend/app/services/run_fold.py (and the PWA's `lib/runs/instant.ts`).
///
/// The accepted form is the API's date-time (sync-protocol.md §1.5), as the PWA port reads it:
/// `YYYY-MM-DDTHH:MM:SS`, an optional fraction of any length, then `Z` or `±HH:MM`.
public enum RunInstant {
    static let msPerDay = 86_400_000

    /// A wire date-time as epoch milliseconds, truncated (sub-millisecond digits dropped); nil when
    /// it isn't in the wire profile.
    public static func parse(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        var i = 0
        func digits(_ count: Int) -> Int? {
            guard i + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[i..<(i + count)] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            i += count
            return value
        }
        func take(_ characters: String) -> Bool {
            guard i < bytes.count, characters.utf8.contains(bytes[i]) else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), take("-"), let month = digits(2), take("-"), let day = digits(2), take("T"),
            let hour = digits(2), take(":"), let minute = digits(2), take(":"), let second = digits(2)
        else { return nil }
        // The first three fraction digits are the milliseconds; the rest are dropped (truncation).
        var milliseconds = 0
        if take(".") {
            var count = 0
            while let digit = digits(1) {
                count += 1
                if count <= 3 { milliseconds = milliseconds * 10 + digit }
            }
            guard count > 0 else { return nil }
            for _ in min(count, 3)..<3 { milliseconds *= 10 }
        }
        var offsetMinutes = 0
        if !take("Z") {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") else { return nil }
            let sign = bytes[i] == UInt8(ascii: "-") ? -1 : 1
            i += 1
            guard let oh = digits(2), take(":"), let om = digits(2), oh <= 23, om <= 59 else { return nil }
            offsetMinutes = sign * (oh * 60 + om)
        }
        guard i == bytes.count, (1...12).contains(month), day >= 1, day <= daysInMonth(year, month), hour <= 23,
            minute <= 59, second <= 59
        else { return nil }
        let local =
            daysFromCivil(year, month, day) * msPerDay + ((hour * 60 + minute) * 60 + second) * 1000 + milliseconds
        return local - offsetMinutes * 60_000
    }

    /// Epoch milliseconds as the server writes an instant: UTC, `Z`, and six fraction digits only
    /// when the millisecond part isn't zero (pydantic's form).
    public static func format(_ ms: Int) -> String {
        let days = floorDiv(ms, msPerDay)
        let rest = ms - days * msPerDay
        let (y, mo, d) = civilFromDays(days)
        let milli = rest % 1000
        let seconds = rest / 1000
        let head =
            "\(pad(y, 4))-\(pad(mo))-\(pad(d))T\(pad(seconds / 3600)):\(pad(seconds / 60 % 60)):\(pad(seconds % 60))"
        return milli == 0 ? "\(head)Z" : "\(head).\(pad(milli, 3))000Z"
    }

    /// Device time as epoch milliseconds, truncated: the one place a run instant comes from a
    /// `Date` (the device clock, §5.1).
    public static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// An instant as a `Date`, for display only.
    public static func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// Floored division (towards −∞), like Python's `//`.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (H. Hinnant's `days_from_civil`).
    static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let yy = m <= 2 ? y - 1 : y
        let era = floorDiv(yy, 400)
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The inverse of `daysFromCivil`.
    static func civilFromDays(_ z: Int) -> (Int, Int, Int) {
        let zz = z + 719_468
        let era = floorDiv(zz, 146_097)
        let doe = zz - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        daysFromCivil(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - daysFromCivil(y, m, 1)
    }

    private static func pad(_ n: Int, _ width: Int = 2) -> String {
        let text = String(n)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
