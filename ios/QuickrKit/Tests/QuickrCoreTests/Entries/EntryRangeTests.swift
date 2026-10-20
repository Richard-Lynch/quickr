import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/entries-range-vectors.json`, from the PWA's own `rangeStart` (pinned to the
/// file's timezone): the entries page's "7/30/90 days" lower bound, and how a `range` value parses.
@Suite struct EntryRangeTests {
    struct Vectors: Decodable {
        struct Meta: Decodable { var timezone: String }

        struct Case: Decodable, Sendable, CustomTestStringConvertible {
            var name: String
            var now: Date
            var range: String
            var expected: String?
            var testDescription: String { name }
        }

        struct Parse: Decodable, Sendable, CustomTestStringConvertible {
            var raw: String?
            var expected: String
            var testDescription: String { "\(raw.map { "\"\($0)\"" } ?? "nil") → \(expected)" }
        }

        var meta: Meta
        var cases: [Case]
        var parse: [Parse]
    }

    static let vectors: Vectors = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        do {
            return try decoder.decode(Vectors.self, from: Fixtures.data("entries-range-vectors.json"))
        } catch {
            fatalError("entries-range-vectors.json: \(error)")
        }
    }()

    static var zone: TimeZone { TimeZone(identifier: vectors.meta.timezone)! }

    @Test(arguments: vectors.cases)
    func startsLikeThePWA(_ vector: Vectors.Case) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let range = try #require(EntryRange(rawValue: vector.range))
        let start = range.start(now: vector.now, calendar: calendar)
        // The PWA's `toOffsetIso`: local wall time with the offset at that instant.
        #expect(start.map(Self.offsetISO) == vector.expected)
    }

    @Test(arguments: vectors.parse)
    func parsesLikeThePWA(_ vector: Vectors.Parse) {
        #expect(EntryRange(parsing: vector.raw).rawValue == vector.expected)
    }

    /// `2026-10-15T00:00:00+01:00`: wall time and offset, `+00:00` rather than `Z`.
    static func offsetISO(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date) / 60
        func pad(_ n: Int) -> String { String(format: "%02d", abs(n)) }
        return "\(c.year!)-\(pad(c.month!))-\(pad(c.day!))T\(pad(c.hour!)):\(pad(c.minute!)):\(pad(c.second!))"
            + "\(offset >= 0 ? "+" : "-")\(pad(offset / 60)):\(pad(offset % 60))"
    }
}
