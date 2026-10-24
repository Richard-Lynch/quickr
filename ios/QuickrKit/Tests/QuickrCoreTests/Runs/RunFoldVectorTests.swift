import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// R1 (timers.md §13.3): Swift/Python parity for the run fold. Every case in
/// shared/fixtures/run-fold-vectors.json (generated from backend/app/services/run_fold.py by
/// `make vectors`) gives the same state, effects and timing here, with instants parsed to integer
/// milliseconds (no `Date`). One test walks every case, so none can be filtered out or skipped.
@Suite struct RunFoldVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var runId: String
            var maxRunMs: Int

            enum CodingKeys: String, CodingKey {
                case runId = "run_id"
                case maxRunMs = "max_run_ms"
            }
        }

        struct Expected: Decodable {
            var state: RunWire.State
            var timing: RunWire.WireTiming?
        }

        struct Case: Decodable {
            var name: String
            var steps: String
            var events: [RunWire.Event]
            var frozen: RunWire.Frozen?
            var expected: Expected
        }

        var meta: Meta
        var stepSets: [String: [RunWire.Step]]
        var cases: [Case]

        enum CodingKeys: String, CodingKey {
            case meta, cases
            case stepSets = "step_sets"
        }
    }

    static func load() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Fixtures.data("run-fold-vectors.json"))
    }

    @Test func casesHaveUniqueNamesAndTheSameLimit() throws {
        let vectors = try Self.load()
        #expect(vectors.cases.count >= 40)
        #expect(Set(vectors.cases.map(\.name)).count == vectors.cases.count)
        #expect(vectors.meta.maxRunMs == RunFold.maxRunMs)
    }

    @Test func everyCaseMatchesTheReference() throws {
        let vectors = try Self.load()
        var ran: [String] = []
        for c in vectors.cases {
            let steps = try #require(vectors.stepSets[c.steps], "\(c.name): unknown step set \(c.steps)").map(\.domain)
            let state = try RunFold.fold(
                runId: vectors.meta.runId, steps: steps, events: c.events.map { try $0.domain() },
                frozen: try c.frozen?.domain())
            #expect(RunWire.State(state) == c.expected.state, "\(c.name): state")
            if let expected = c.expected.timing {
                let timing = try RunFold.projectTiming(state, steps: steps)
                #expect(RunWire.WireTiming(timing) == expected, "\(c.name): timing")
                // Exact integer sums (T5).
                #expect(timing.segments.reduce(0) { $0 + $1.activeMs } == timing.activeMs, "\(c.name)")
                #expect(timing.segments.reduce(0) { $0 + $1.pausedMs } == timing.pausedMs, "\(c.name)")
            } else {
                #expect(state.status != .stopped, "\(c.name): a stopped run has a timing")
                #expect(throws: RunFold.FoldError.notStopped) { try RunFold.projectTiming(state, steps: steps) }
            }
            ran.append(c.name)
        }
        #expect(ran == vectors.cases.map(\.name), "every case ran")
    }

    @Test func aMissingStartThrows() {
        let event = RunEvent(id: "0e000000-0000-4000-8000-000000000001", type: .next, at: 0, seg: 0)
        #expect(throws: RunFold.FoldError.missingStart) {
            try RunFold.fold(runId: "0a000000-0000-4000-8000-000000000000", steps: [], events: [event])
        }
    }
}
