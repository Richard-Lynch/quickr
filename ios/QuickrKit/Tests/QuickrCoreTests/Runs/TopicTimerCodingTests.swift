import Foundation
import QuickrCore
import Testing

/// R13's second half (timers2.md §12.3): `TopicTimer` decodes v1 and v2 JSON (§1.1, §1.4). v1's
/// `{steps: [{key, label}]}` is still on the wire from older servers and in the store's
/// `timer_json`; missing lists and alerts default to `[]`.
@Suite struct TopicTimerCodingTests {
    static func decode(_ json: String) throws -> TopicTimer {
        try JSONDecoder().decode(TopicTimer.self, from: Data(json.utf8))
    }

    @Test func v1JSONDecodesWithEmptyLists() throws {
        let timer = try Self.decode(#"{"steps": [{"key": "pour", "label": "Pour"}]}"#)
        #expect(timer.steps == [TopicTimer.Step(key: "pour", label: "Pour")])
        #expect(timer.steps[0].alerts.isEmpty)
        #expect(timer.laps.isEmpty)
        #expect(timer.variables.isEmpty)
    }

    @Test func v2JSONDecodesEveryField() throws {
        let timer = try Self.decode(
            #"""
            {"steps": [{"key": "warmup", "label": "Warmup", "alerts": [
                {"key": "half", "label": "Half way", "at": "t/2", "at_ms": 30000}]}],
             "laps": [{"key": "run", "label": "Run", "alerts": []},
                      {"key": "rest", "label": "Rest", "alerts": [{"key": "go", "label": "Go", "at": "rest", "at_ms": 20000}]}],
             "variables": [{"name": "t", "ms": 60000}, {"name": "rest", "ms": 20000}]}
            """#)
        #expect(timer.steps[0].alerts == [TopicTimer.Alert(key: "half", label: "Half way", at: "t/2", atMs: 30000)])
        #expect(timer.laps.map(\.key) == ["run", "rest"])
        #expect(timer.laps[1].alerts.map(\.atMs) == [20000])
        #expect(timer.variables == [TopicTimer.Variable(name: "t", ms: 60000), .init(name: "rest", ms: 20000)])
    }

    /// The fold generator's `timer_sets` (`{steps, laps}` without alerts or variables) decode
    /// too: a lap type without `alerts`, a timer without `variables`.
    @Test func partialV2JSONDecodes() throws {
        let timer = try Self.decode(#"{"steps": [], "laps": [{"key": "cig", "label": "Cig"}]}"#)
        #expect(timer.laps == [TopicTimer.LapType(key: "cig", label: "Cig")])
        #expect(timer.variables.isEmpty)
    }

    /// An alert without `at_ms` (a client's own draft; the server fills it) decodes with nil.
    @Test func anAlertMayLackAtMs() throws {
        let timer = try Self.decode(
            #"{"steps": [{"key": "a", "label": "A", "alerts": [{"key": "x", "label": "X", "at": "30s"}]}]}"#)
        #expect(timer.steps[0].alerts[0].atMs == nil)
    }

    @Test func roundTripsAndKeepsAV1TimerV1OnTheWire() throws {
        let v2 = TopicTimer(
            steps: [.init(key: "a", label: "A", alerts: [.init(key: "x", label: "X", at: "t", atMs: 1000)])],
            laps: [.init(key: "run", label: "Run")], variables: [.init(name: "t", ms: 1000)])
        let data = try JSONEncoder().encode(v2)
        #expect(try JSONDecoder().decode(TopicTimer.self, from: data) == v2)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["laps"] != nil && object["variables"] != nil)
        let step = try #require((object["steps"] as? [[String: Any]])?.first)
        let alert = try #require((step["alerts"] as? [[String: Any]])?.first)
        #expect(alert["at_ms"] as? Int == 1000)

        // A v1-shaped timer encodes as v1 until the server takes v2 input (see Topic.swift).
        let v1 = TopicTimer(steps: [.init(key: "pour", label: "Pour")])
        let plain = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(v1)) as? [String: Any])
        #expect(Set(plain.keys) == ["steps"])
        #expect(Set(((plain["steps"] as? [[String: Any]])?.first ?? [:]).keys) == ["key", "label"])
    }
}
