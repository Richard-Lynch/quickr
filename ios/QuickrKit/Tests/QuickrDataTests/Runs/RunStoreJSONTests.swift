import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// A run cached by a build from before fold v4 (`run.run_json` without `terminal_id`,
/// `next_lap_type`, `lap_count` and `open.lap_type`) still reads from the store, while the same
/// JSON off the wire fails: the v2 `RunState` keys stay required there (timers2.md §3.3).
@Suite struct RunStoreJSONTests {
    /// `recordRunEvent.next`'s run (open: a step) as a pre-v4 build stored it.
    static func legacyRunJSON() throws -> String {
        let body = try #require(try Fixtures.api("recordRunEvent.next").body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        var run = try #require(object["run"] as? [String: Any])
        var state = try #require(run["state"] as? [String: Any])
        for key in ["terminal_id", "next_lap_type", "lap_count"] { state[key] = nil }
        var open = try #require(state["open"] as? [String: Any])
        open["lap_type"] = nil
        state["open"] = open
        run["state"] = state
        return String(decoding: try JSONSerialization.data(withJSONObject: run), as: UTF8.self)
    }

    @Test func aPreV4CachedRunReadsFromTheStore() throws {
        let json = try Self.legacyRunJSON()
        let run = try StoreJSON.decode(RunDTO.self, json).toDomain()
        #expect(run.state.terminalId == nil)
        #expect(run.state.nextLapType == nil)
        #expect(run.state.lapCount == run.state.segments.count { $0.kind == .lap })
        #expect(run.state.open?.lapType == nil)
        #expect(run.state.open?.label == "Drink")
    }

    @Test func theSameJSONOffTheWireFails() throws {
        let json = try Self.legacyRunJSON()
        #expect(throws: (any Error).self) { try WireCoding.decoder().decode(RunDTO.self, from: Data(json.utf8)) }
    }

    @Test func aV4RunRoundTripsThroughTheStore() throws {
        let body = try #require(try Fixtures.api("getRun").body)
        let run = try RunDTO.decode(body, using: WireCoding.decoder()).toDomain()
        let stored = try StoreJSON.encode(RunDTO(run))
        #expect(try StoreJSON.decode(RunDTO.self, stored).toDomain() == run)
    }
}
