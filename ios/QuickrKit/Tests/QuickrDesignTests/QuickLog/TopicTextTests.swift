import Foundation
import QuickrCore
import QuickrUI
import Testing

@Suite(.timeLimit(.minutes(2))) struct TopicTextTests {
    static let text: TopicText = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return TopicText(calendar: calendar, locale: Locale(identifier: "en_US"))
    }()

    /// Times read like `Intl` in a browser: a narrow no-break space (U+202F) before AM/PM.
    /// Wed 2026-10-21 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_584_000)

    static func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    @Test func relativeTimesUseTheLargestUnitAndNamedDays() {
        #expect(Self.text.relative(nil, now: Self.now) == "never")
        #expect(Self.text.relative(Self.at(-0.5), now: Self.now) == "just now")
        #expect(Self.text.relative(Self.at(-5), now: Self.now) == "5 minutes ago")
        #expect(Self.text.relative(Self.at(-4 * 60), now: Self.now) == "4 hours ago")
        #expect(Self.text.relative(Self.at(-26 * 60), now: Self.now) == "yesterday")
        #expect(Self.text.relative(Self.at(-15 * 24 * 60), now: Self.now) == "2 weeks ago")
    }

    @Test func answersReadWithLabelsUnitsAndDecimals() {
        let severity = Question(
            key: "s", label: "Severity", required: true,
            kind: .choice(.init(options: [EnumOption(value: "mild", label: "Mild")], multiple: false)))
        #expect(Self.text.answer(.string("mild"), for: severity) == "Mild")
        #expect(Self.text.answer(.string("gone"), for: severity) == "gone")  // an option since removed
        #expect(Self.text.answer(.strings(["mild", "x"]), for: severity) == "Mild, x")
        #expect(Self.text.answer(.int(3), for: severity) == nil)

        let glasses = Question(key: "g", label: "Glasses", required: true, kind: .int(.init(unit: "glasses")))
        #expect(Self.text.answer(.int(1500), for: glasses) == "1,500 glasses")
        let km = Question(key: "k", label: "Distance", required: true, kind: .double(.init(decimals: 1, unit: "km")))
        #expect(Self.text.answer(.double(5.25), for: km) == "5.2 km")
        let free = Question(key: "w", label: "Weight", required: true, kind: .double(.init()))
        #expect(Self.text.answer(.double(70.1234), for: free) == "70.123")
        #expect(Self.text.answer(.string("70"), for: free) == nil)
    }

    @Test func countsUsePlurals() {
        #expect(Self.text.count(1, "entry", "entries") == "1 entry")
        #expect(Self.text.count(1234, "entry", "entries") == "1,234 entries")
        #expect(Self.text.count(2, "glass", "glasses") == "2 glasses")
    }
}
