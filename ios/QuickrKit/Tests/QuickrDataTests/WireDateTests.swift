import Foundation
import QuickrData
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(2))) struct WireDateTests {
    @Test(arguments: [
        ("2026-06-01T12:00:00.123456Z", 1_780_315_200.123456, "2026-06-01T12:00:00.123456+00:00"),
        ("2026-03-04T08:00:00Z", 1_772_611_200, "2026-03-04T08:00:00+00:00"),
        ("2026-03-04T12:00:00.5Z", 1_772_625_600.5, "2026-03-04T12:00:00.500000+00:00"),
        ("2026-03-04T13:00:00+01:00", 1_772_625_600, "2026-03-04T12:00:00+00:00"),
        ("2026-03-04T06:30:00-05:30", 1_772_625_600, "2026-03-04T12:00:00+00:00"),
        ("2000-01-01T00:00:00Z", 946_684_800, "2000-01-01T00:00:00+00:00"),
        ("2024-02-29T23:59:59.000001z", 1_709_251_199.000001, "2024-02-29T23:59:59.000001+00:00"),
        ("1969-12-31T23:59:59.9Z", -0.1, "1969-12-31T23:59:59.900000+00:00"),
    ])
    func parsesAndFormats(input: String, seconds: Double, output: String) throws {
        let date = try #require(WireDate.parse(input))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.000_000_5)
        #expect(WireDate.format(date) == output)
        #expect(WireDate.parse(output) == date)
    }

    @Test(arguments: [
        "2026-06-01T12:00:00", "2026-06-01T12:00:00.1234567Z", "2026-06-01T12:00:00.Z", "2026-06-01 12:00:00Z",
        "2026-13-01T12:00:00Z", "2026-02-29T12:00:00Z", "2026-06-01T24:00:00Z", "2026-06-01T12:00:60Z",
        "2026-06-01T12:00:00+0100", "2026-06-01T12:00:00+01", "2026-06-01T12:00:00Zjunk", "", "not a date",
    ])
    func rejectsMalformed(input: String) {
        #expect(WireDate.parse(input) == nil)
    }

    /// Every date in every fixture parses and survives a format round trip at microsecond precision.
    @Test func everyFixtureDateRoundTrips() throws {
        var count = 0
        for fixture in try Fixtures.allAPI() {
            for body in [fixture.body, fixture.requestBody].compactMap({ $0 }) {
                for text in Self.dateStrings(
                    in: try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed))
                {
                    let date = try #require(WireDate.parse(text), "\(fixture.name): \(text)")
                    #expect(WireDate.parse(WireDate.format(date)) == date, "\(fixture.name): \(text)")
                    count += 1
                }
            }
        }
        #expect(count > 100)
    }

    @Test func encoderWritesExplicitOffsets() throws {
        struct Box: Codable, Equatable { var at: Date }
        let box = Box(at: try #require(WireDate.parse("2026-06-01T12:00:00.123456Z")))
        let data = try WireCoding.encoder().encode(box)
        #expect(String(decoding: data, as: UTF8.self) == #"{"at":"2026-06-01T12:00:00.123456+00:00"}"#)
        #expect(try WireCoding.decoder().decode(Box.self, from: data) == box)
    }

    private static func dateStrings(in value: Any) -> [String] {
        switch value {
        case let string as String:
            string.count >= 20 && string.dropFirst(4).hasPrefix("-") && string.dropFirst(10).hasPrefix("T")
                ? [string] : []
        case let array as [Any]: array.flatMap(dateStrings)
        case let object as [String: Any]: object.values.flatMap(dateStrings)
        default: []
        }
    }
}
