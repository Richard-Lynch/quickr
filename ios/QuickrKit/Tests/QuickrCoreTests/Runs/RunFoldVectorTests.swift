import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// R1 (timers.md §13.3) / R13 (timers2.md §12.3): Swift/Python parity for the run fold v4. Every case in
/// shared/fixtures/run-fold-vectors.json (generated from backend/app/services/run_fold.py by
/// `make vectors`) gives the same state, effects and timing here, with instants parsed to integer
/// milliseconds (no `Date`). One test walks every case, so none can be filtered out or skipped.
@Suite struct RunFoldVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var runId: String
            var maxRunMs: Int
            var generatorVersion: Int

            enum CodingKeys: String, CodingKey {
                case runId = "run_id"
                case maxRunMs = "max_run_ms"
                case generatorVersion = "generator_version"
            }
        }

        struct Expected: Decodable {
            var state: RunWire.State
            var timing: RunWire.WireTiming?
        }

        struct Case: Decodable {
            var name: String
            var timer: String
            var events: [RunWire.Event]
            var frozen: RunWire.Frozen?
            var expected: Expected
        }

        /// A stored entry timing as clients decode it, and as it is served (pre-v2 ids read null).
        struct StoredTiming: Decodable {
            var name: String
            var stored: RunWire.WireTiming
            var expected: RunWire.WireTiming
        }

        var meta: Meta
        var timerSets: [String: RunWire.Timer]
        var cases: [Case]
        var timings: [StoredTiming]

        enum CodingKeys: String, CodingKey {
            case meta, cases, timings
            case timerSets = "timer_sets"
        }
    }

    static func load() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Fixtures.data("run-fold-vectors.json"))
    }

    @Test func casesHaveUniqueNamesAndTheSameLimit() throws {
        let vectors = try Self.load()
        #expect(vectors.cases.count >= 90)
        #expect(vectors.meta.generatorVersion == 4)
        #expect(Set(vectors.cases.map(\.name)).count == vectors.cases.count)
        #expect(vectors.meta.maxRunMs == RunFold.maxRunMs)
    }

    @Test func everyCaseMatchesTheReference() throws {
        let vectors = try Self.load()
        var ran: [String] = []
        for c in vectors.cases {
            let timer = try #require(vectors.timerSets[c.timer], "\(c.name): unknown timer set \(c.timer)").domain
            let state = try RunFold.fold(
                runId: vectors.meta.runId, timer: timer, events: c.events.map { try $0.domain() },
                frozen: try c.frozen?.domain())
            #expect(RunWire.State(state) == c.expected.state, "\(c.name): state")
            if let expected = c.expected.timing {
                let timing = try RunFold.projectTiming(state, steps: timer.steps)
                #expect(RunWire.WireTiming(timing) == expected, "\(c.name): timing")
                // Exact integer sums (T5).
                #expect(timing.segments.reduce(0) { $0 + $1.activeMs } == timing.activeMs, "\(c.name)")
                #expect(timing.segments.reduce(0) { $0 + $1.pausedMs } == timing.pausedMs, "\(c.name)")
            } else {
                #expect(state.status != .stopped, "\(c.name): a stopped run has a timing")
                #expect(throws: RunFold.FoldError.notStopped) {
                    try RunFold.projectTiming(state, steps: timer.steps)
                }
            }
            ran.append(c.name)
        }
        #expect(ran == vectors.cases.map(\.name), "every case ran")
    }

    /// M1-REVIEW (test evidence): `RunWire.State` and `WireTiming` decode the raw JSON with no
    /// key left over or missing, so a key the server adds can't be silently ignored here.
    @Test func wireShapesCoverEveryKeyOfTheRawJSON() throws {
        let raw = try #require(
            try JSONSerialization.jsonObject(with: Fixtures.data("run-fold-vectors.json")) as? [String: Any])
        func keys<K: CodingKey & CaseIterable>(_: K.Type) -> Set<String> { Set(K.allCases.map(\.stringValue)) }
        let segment = keys(RunWire.Segment.CodingKeys.self)
        let pause: Set<String> = ["start", "end", "id"]
        func check(_ object: Any?, _ expected: Set<String>, _ at: String) {
            guard let object = object as? [String: Any] else {
                Issue.record("\(at): not an object")
                return
            }
            #expect(Set(object.keys) == expected, "\(at)")
        }
        func checkTiming(_ timing: [String: Any], _ at: String) {
            check(timing, keys(RunWire.WireTiming.CodingKeys.self), at)
            for s in timing["segments"] as? [Any] ?? [] { check(s, segment, "\(at).segments[]") }
            for p in timing["pauses"] as? [Any] ?? [] { check(p, pause, "\(at).pauses[]") }
        }
        let cases = try #require(raw["cases"] as? [[String: Any]])
        var states = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let expected = try #require(c["expected"] as? [String: Any], "\(name)")
            let state = try #require(expected["state"] as? [String: Any], "\(name)")
            states += 1
            check(state, keys(RunWire.State.CodingKeys.self), "\(name).state")
            if let open = state["open"] as? [String: Any] {
                check(open, keys(RunWire.Open.CodingKeys.self), "\(name).state.open")
            }
            for s in state["segments"] as? [Any] ?? [] { check(s, segment, "\(name).state.segments[]") }
            for p in state["pauses"] as? [Any] ?? [] { check(p, pause, "\(name).state.pauses[]") }
            for (_, e) in state["effects"] as? [String: Any] ?? [:] {
                check(e, ["effect", "reason"], "\(name).state.effects")
            }
            if let timing = expected["timing"] as? [String: Any] { checkTiming(timing, "\(name).timing") }
        }
        #expect(states == cases.count)
        for t in raw["timings"] as? [[String: Any]] ?? [] {
            if let expected = t["expected"] as? [String: Any] { checkTiming(expected, "timings.expected") }
        }
    }

    /// `timings`: a stored v1 timing reads with null ids and lap types (timers2.md §3.3).
    @Test func storedTimingsReadAsServed() throws {
        let vectors = try Self.load()
        #expect(!vectors.timings.isEmpty)
        for t in vectors.timings {
            let timing = try t.stored.domain()
            #expect(RunWire.WireTiming(timing) == t.expected, "\(t.name)")
        }
    }

    /// The v4 cases cover the new void reasons and event types.
    @Test func v4CasesCoverTheNewReasons() throws {
        let vectors = try Self.load()
        var reasons: Set<String> = []
        for c in vectors.cases {
            for effect in c.expected.state.effects.values { if let r = effect.reason { reasons.insert(r) } }
        }
        for reason in [VoidReason.reverted, .notStopped, .deleted, .noTarget] {
            #expect(reasons.contains(reason.rawValue), "no case voids \(reason.rawValue)")
        }
    }

    @Test func aMissingStartThrows() {
        let event = RunEvent(id: "0e000000-0000-4000-8000-000000000001", type: .next, at: 0, seg: 0)
        #expect(throws: RunFold.FoldError.missingStart) {
            try RunFold.fold(
                runId: "0a000000-0000-4000-8000-000000000000", timer: TopicTimer(steps: []), events: [event])
        }
    }
}
