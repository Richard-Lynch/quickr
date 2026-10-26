import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// R1 (timers.md §13.3): `fmtDuration` (`DurationFormat.format`) against every case in
/// shared/fixtures/duration-format-vectors.json (from `run_fold.fmt_duration`). One test walks
/// every case.
@Suite struct DurationFormatVectorTests {
    struct Case: Decodable {
        var name: String
        var ms: Int
        var expected: String
    }

    @Test func everyCaseMatchesTheReference() throws {
        struct File: Decodable { var cases: [Case] }
        let cases = try JSONDecoder().decode(File.self, from: Fixtures.data("duration-format-vectors.json")).cases
        #expect(cases.count >= 9)
        #expect(Set(cases.map(\.name)).count == cases.count)
        var ran: [String] = []
        for c in cases {
            #expect(DurationFormat.format(c.ms) == c.expected, "\(c.name)")
            ran.append(c.name)
        }
        #expect(ran == cases.map(\.name), "every case ran")
    }
}
