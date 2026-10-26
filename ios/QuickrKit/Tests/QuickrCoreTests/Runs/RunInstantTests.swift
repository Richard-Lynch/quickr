import Foundation
import QuickrCore
import Testing

/// Wire instants as integer epoch milliseconds (timers.md §2.3), the PWA's `instant.test.ts`.
@Suite struct RunInstantTests {
    /// Epoch milliseconds of a UTC calendar instant, from Foundation, for comparison only.
    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, _ ms: Int = 0) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
        return Int(date.timeIntervalSince1970) * 1000 + ms
    }

    @Test func readsUTCAndOffsetForms() {
        #expect(RunInstant.parse("1970-01-01T00:00:00Z") == 0)
        #expect(RunInstant.parse("2026-10-23T08:00:00Z") == Self.utc(2026, 10, 23, 8))
        #expect(RunInstant.parse("2026-10-23T09:00:00+01:00") == Self.utc(2026, 10, 23, 8))
        #expect(RunInstant.parse("2026-10-23T03:00:00-05:00") == Self.utc(2026, 10, 23, 8))
        #expect(RunInstant.parse("2024-02-29T23:59:59.999Z") == Self.utc(2024, 2, 29, 23, 59, 59, 999))
    }

    @Test func truncatesSubMillisecondDigits() {
        #expect(RunInstant.parse("2026-10-23T08:00:00.000999Z") == Self.utc(2026, 10, 23, 8))
        #expect(RunInstant.parse("2026-10-23T08:00:00.9999999Z") == Self.utc(2026, 10, 23, 8, 0, 0, 999))
        #expect(RunInstant.parse("2026-10-23T08:00:00.5Z") == Self.utc(2026, 10, 23, 8, 0, 0, 500))
        // Before the epoch, truncation is still toward the earlier millisecond (Python's floor).
        #expect(RunInstant.parse("1969-12-31T23:59:59.999900Z") == -1)
    }

    @Test(arguments: [
        "2026-10-23T08:00:00", "2026-10-23 08:00:00Z", "2026-13-01T00:00:00Z", "2026-02-29T00:00:00Z",
        "2026-10-23T24:00:00Z", "2026-10-23T08:00:60Z", "2026-10-23T08:00:00+0100", "2026-10-23T08:00:00.Z",
        "2026-10-23T08:00:00z", "2026-10-23T08:00:00+24:00", "2026-10-23T08:00:00Zx", "",
    ])
    func refuses(_ text: String) {
        #expect(RunInstant.parse(text) == nil)
    }

    @Test func writesTheAPIForm() {
        #expect(RunInstant.format(0) == "1970-01-01T00:00:00Z")
        #expect(RunInstant.format(Self.utc(2026, 10, 23, 8, 0, 1, 1)) == "2026-10-23T08:00:01.001000Z")
        #expect(RunInstant.format(-1) == "1969-12-31T23:59:59.999000Z")
    }

    /// Foundation's calendar fields to the whole second (a whole-second `Date` is exact; its own
    /// fraction formatting rounds through a `Double`), and the millisecond digits by arithmetic.
    @Test func roundTripsAndAgreesWithFoundationAcrossYears() {
        var style = Date.ISO8601FormatStyle()
        style.timeZone = TimeZone(identifier: "UTC")!
        for i in 0..<2000 {
            let ms = (i * 7_919_993_717) % 8_000_000_000_000 - 1_000_000_000_000
            let text = RunInstant.format(ms)
            #expect(RunInstant.parse(text) == ms, "\(text)")
            let seconds = Int((Double(ms) / 1000).rounded(.down))
            let milli = ms - seconds * 1000
            let head = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(style).dropLast()  // "Z"
            let expected = milli == 0 ? "\(head)Z" : "\(head).\(String(format: "%03d", milli))000Z"
            #expect(text == expected, "\(ms)")
        }
    }

    @Test func deviceTimeTruncates() {
        #expect(RunInstant.milliseconds(Date(timeIntervalSince1970: 1.9999)) == 1999)
        #expect(RunInstant.milliseconds(Date(timeIntervalSince1970: -0.0005)) == -1)
    }
}
