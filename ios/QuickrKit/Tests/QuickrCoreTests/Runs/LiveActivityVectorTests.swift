import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// timers.md §10.4: the Live Activity payloads the server sends (shared/fixtures/
/// live-activity-vectors.json, generated from backend/app/services/push/live_activity.py by
/// `make vectors`). Each `content-state` decodes into `RunActivityState` and each start's
/// `attributes` into `RunActivityAttributes`; each case's run, folded here, builds the same
/// content state (`RunActivityContent`), so the app's local updates show what the pushes show.
@Suite struct LiveActivityVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var attributesType: String
            var maxLabelLength: Int
            var staleSeconds: Double
            var dismissSeconds: Double

            enum CodingKeys: String, CodingKey {
                case attributesType = "attributes_type"
                case maxLabelLength = "max_label_length"
                case staleSeconds = "stale_seconds"
                case dismissSeconds = "dismiss_seconds"
            }
        }

        struct Run: Decodable {
            var events: [RunWire.Event]
            var status: String?
            var revision: Int
        }

        struct Aps: Decodable {
            var event: String
            var contentState: RunActivityState
            var attributes: RunActivityAttributes?
            var attributesType: String?

            enum CodingKeys: String, CodingKey {
                case event
                case contentState = "content-state"
                case attributes
                case attributesType = "attributes-type"
            }
        }

        struct Payload: Decodable {
            var aps: Aps
        }

        struct Case: Decodable {
            var name: String
            var event: String
            var steps: String
            var run: Run
            var payload: Payload
        }

        var meta: Meta
        var stepSets: [String: [RunWire.Step]]
        var cases: [Case]

        enum CodingKeys: String, CodingKey {
            case meta, cases
            case stepSets = "step_sets"
        }
    }

    static let file = "live-activity-vectors.json"

    static func load() throws -> Vectors { try JSONDecoder().decode(Vectors.self, from: Fixtures.data(file)) }

    /// A case's content state as the server sent it.
    static func state(_ name: String) throws -> RunActivityState {
        let vectors = try load()
        let found = try #require(vectors.cases.first { $0.name == name }, "no case \(name)")
        return found.payload.aps.contentState
    }

    @Test func constantsMatchTheServer() throws {
        let meta = try Self.load().meta
        let type = String(describing: RunActivityAttributes.self)
        #expect(meta.attributesType == type)
        #expect(meta.maxLabelLength == RunActivityContent.maxLabelLength)
        #expect(meta.staleSeconds == RunActivityContent.staleSeconds)
        #expect(meta.dismissSeconds == RunActivityContent.dismissSeconds)
    }

    @Test func everyEventIsCovered() throws {
        let events = Set(try Self.load().cases.map(\.event))
        #expect(events == ["start", "update", "end"])
    }

    @Test func everyCaseBuildsTheServersContentState() throws {
        let vectors = try Self.load()
        var ran: [String] = []
        for c in vectors.cases {
            let steps = try #require(vectors.stepSets[c.steps], "\(c.name): unknown step set").map(\.domain)
            let events = try c.run.events.map { try $0.domain() }
            let runId = try #require(events.first?.id)
            let folded = try RunFold.fold(runId: runId, steps: steps, events: events)
            let status = try #require(c.run.status.map { RunStatus(rawValue: $0) } ?? folded.status, "\(c.name)")
            let built = RunActivityContent.state(
                runId: runId, revision: c.run.revision, status: status, state: folded, steps: steps)
            let sent = c.payload.aps.contentState
            #expect(built == sent, "\(c.name)")
            ran.append(c.name)
        }
        #expect(ran.count == vectors.cases.count)
    }

    @Test func startsCarryTheAttributes() throws {
        let vectors = try Self.load()
        let starts = vectors.cases.filter { $0.event == "start" }
        #expect(starts.count == 2)
        for c in starts {
            let sent = try #require(c.payload.aps.attributes, "\(c.name)")
            let type = c.payload.aps.attributesType
            #expect(type == "RunActivityAttributes")
            let topicId = try #require(UUID(uuidString: sent.topicId))
            let longName = String(repeating: "T", count: 200)
            let name = c.name == "start_longest_labels" ? longName : "Morning routine"
            let built = RunActivityContent.attributes(serverId: sent.serverId, topicId: topicId, topicName: name)
            #expect(built == sent, "\(c.name)")
            let length = built.topicName.unicodeScalars.count
            #expect(length <= RunActivityContent.maxLabelLength)
        }
    }

    /// What the app encodes decodes as the server's: no field renamed or dropped.
    @Test func contentStateRoundTrips() throws {
        for c in try Self.load().cases {
            let sent = c.payload.aps.contentState
            let data = try JSONEncoder().encode(sent)
            let again = try JSONDecoder().decode(RunActivityState.self, from: data)
            #expect(again == sent, "\(c.name)")
        }
    }

    @Test func truncateCountsScalarsAndKeepsTheEllipsis() {
        let short = RunActivityContent.truncate("Shower")
        #expect(short == "Shower")
        let exact = String(repeating: "é", count: 64)
        let kept = RunActivityContent.truncate(exact)
        #expect(kept == exact)
        let long = RunActivityContent.truncate(String(repeating: "é", count: 65))
        let count = long.unicodeScalars.count
        #expect(count == 64)
        #expect(long.hasSuffix("…"))
    }
}
