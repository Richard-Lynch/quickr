import Foundation
import QuickrData
import QuickrTestSupport
import Testing

/// `getTopicTiming`'s lap types (timers2.md §7.4) through `TopicTimingDTO`: the recorded API
/// fixtures carry none, so the populated shapes come from `timing-stats-vectors.json` v3, whose
/// `expected` the endpoint answers as-is (`test_api_timing.py`).
@Suite struct TopicTimingLapTypesTests {
    /// The cases whose `expected` has lap-type rows.
    static func cases() -> [[String: Any]] {
        let root = try? JSONSerialization.jsonObject(with: Fixtures.data("timing-stats-vectors.json"))
        let all = (root as? [String: Any])?["cases"] as? [[String: Any]] ?? []
        return all.filter { (($0["expected"] as? [String: Any])?["lap_types"] as? [Any])?.isEmpty == false }
    }

    static let names: [String] = cases().compactMap { $0["name"] as? String }

    static func expected(_ name: String) throws -> [String: Any] {
        let found = try #require(cases().first { $0["name"] as? String == name })
        return try #require(found["expected"] as? [String: Any])
    }

    static func decode(_ json: Any) throws -> TopicTimingDTO {
        try WireCoding.decoder().decode(TopicTimingDTO.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func theVectorsHaveLapTypes() {
        #expect(Self.names.count >= 4)
    }

    @Test(arguments: names)
    func rowsAndSeriesDecode(_ name: String) throws {
        let json = try Self.expected(name)
        let timing = try Self.decode(json)
        let rows = try #require(json["lap_types"] as? [[String: Any]])
        #expect(timing.lapTypes.map(\.key) == rows.map { $0["key"] as? String })
        for (row, want) in zip(timing.lapTypes, rows) {
            #expect(row.label == want["label"] as? String)
            #expect(row.laps == want["laps"] as? Int)
            #expect(row.bestMs == want["best_ms"] as? Int)
            #expect(row.medianMs == want["median_ms"] as? Int)
            #expect(row.meanMs == want["mean_ms"] as? Int)
        }
        let points = try #require(json["series"] as? [[String: Any]])
        #expect(timing.series.map(\.lapTypes) == points.map { $0["lap_types"] as? [String: Int] ?? ["missing": -1] })
    }

    /// Every key of a lap-type row is required, nullable ones too (sync §2.2), as are both
    /// `lap_types` keys themselves.
    @Test func everyLapTypeKeyIsRequired() throws {
        let json = try Self.expected("lap_types_cycle")
        let rows = try #require(json["lap_types"] as? [[String: Any]])
        for key in try #require(rows.first).keys {
            var row = rows[0]
            row[key] = nil
            var broken = json
            broken["lap_types"] = [row] + rows.dropFirst()
            #expect(throws: DecodingError.self, "lap_types/0/\(key)") { try Self.decode(broken) }
        }
        var noRows = json
        noRows["lap_types"] = nil
        #expect(throws: DecodingError.self) { try Self.decode(noRows) }
        var points = try #require(json["series"] as? [[String: Any]])
        points[0]["lap_types"] = nil
        var noMap = json
        noMap["series"] = points
        #expect(throws: DecodingError.self) { try Self.decode(noMap) }
    }
}
