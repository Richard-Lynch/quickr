import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// timers.md §10.4, timers2.md §8: the Live Activity payloads the server sends (shared/fixtures/
/// live-activity-vectors.json, generated from backend/app/services/push/live_activity.py by
/// `make vectors`). Each `content-state` decodes into `RunActivityState` and each start's
/// `attributes` into `RunActivityAttributes`; each case's run, folded here over its timer set at
/// the push's instant, builds the same content state (`RunActivityContent`), so the app's local
/// updates show what the pushes show.
@Suite struct LiveActivityVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var attributesType: String
            var maxLabelLength: Int
            var staleSeconds: Double
            var dismissSeconds: Double
            var maxBytes: Int
            var timestamp: Int
            var budget: Budget

            struct Budget: Decodable {
                var labelLength: Int
                var steps: [String]

                enum CodingKeys: String, CodingKey {
                    case steps
                    case labelLength = "label_length"
                }
            }

            enum CodingKeys: String, CodingKey {
                case timestamp, budget
                case attributesType = "attributes_type"
                case maxLabelLength = "max_label_length"
                case staleSeconds = "stale_seconds"
                case dismissSeconds = "dismiss_seconds"
                case maxBytes = "max_bytes"
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

        /// The server's truncation steps on this body (timers2.md §8.2), at `limit` bytes.
        struct Budget: Decodable {
            var limit: Int
            var steps: [String]
        }

        struct Case: Decodable {
            var name: String
            var event: String
            var timer: String
            var topicName: String
            var run: Run
            var payload: Payload
            var bytes: Int
            var budget: Budget?

            enum CodingKeys: String, CodingKey {
                case name, event, timer, run, payload, bytes, budget
                case topicName = "topic_name"
            }
        }

        var meta: Meta
        var timerSets: [String: TopicTimer]
        var cases: [Case]

        enum CodingKeys: String, CodingKey {
            case meta, cases
            case timerSets = "timer_sets"
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

    /// The server's budget steps (live_activity.py `shrink`) on a state and its attributes: the
    /// app never truncates (its local updates don't go through APNs), so the vectors say what was.
    static func fitted(
        _ state: RunActivityState, _ attributes: RunActivityAttributes?, steps: [String], length: Int
    ) -> (RunActivityState, RunActivityAttributes?) {
        var state = state
        var attributes = attributes
        for step in steps {
            switch step {
            case "alert_label": state.alertLabel = state.alertLabel.map { RunActivityContent.truncate($0, length) }
            case "next_label": state.nextLabel = state.nextLabel.map { RunActivityContent.truncate($0, length) }
            case "label": state.label = RunActivityContent.truncate(state.label, length)
            case "topic_name":
                if let name = attributes?.topicName {
                    attributes?.topicName = RunActivityContent.truncate(name, length)
                }
            default:  // terminal
                state.nextLabel = nil
                state.alertLabel = nil
                attributes?.topicName = ""
            }
        }
        return (state, attributes)
    }

    @Test func constantsMatchTheServer() throws {
        let meta = try Self.load().meta
        let type = String(describing: RunActivityAttributes.self)
        #expect(meta.attributesType == type)
        #expect(meta.maxLabelLength == RunActivityContent.maxLabelLength)
        #expect(meta.staleSeconds == RunActivityContent.staleSeconds)
        #expect(meta.dismissSeconds == RunActivityContent.dismissSeconds)
        #expect(meta.budget.steps == ["alert_label", "next_label", "label", "topic_name", "terminal"])
        #expect(RunActivityContent.version == 1)
    }

    @Test func everyEventIsCovered() throws {
        let events = Set(try Self.load().cases.map(\.event))
        #expect(events == ["start", "update", "end"])
    }

    /// timers2.md §8.2's cases are all there.
    @Test func theTimers2CasesArePresent() throws {
        let names = Set(try Self.load().cases.map(\.name))
        let wanted: Set = [
            "update_tiktok_lap", "update_alert_pending", "update_alert_paused", "start_renamed_laps",
            "update_reopened", "start_longest_labels", "payload_budget_truncation", "payload_budget_terminal",
            "typed_lap_mid_steps",
        ]
        #expect(wanted.isSubset(of: names))
    }

    @Test func everyCaseBuildsTheServersContentState() throws {
        let vectors = try Self.load()
        let now = vectors.meta.timestamp * 1000
        var ran: [String] = []
        for c in vectors.cases {
            let timer = try #require(vectors.timerSets[c.timer], "\(c.name): unknown timer set")
            let events = try c.run.events.map { try $0.domain() }
            let runId = try #require(events.first?.id)
            let folded = try RunFold.fold(runId: runId, timer: timer, events: events)
            let status = try #require(c.run.status.map { RunStatus(rawValue: $0) } ?? folded.status, "\(c.name)")
            let state = RunActivityContent.state(
                runId: runId, revision: c.run.revision, status: status, state: folded, timer: timer, now: now)
            let (built, _) = Self.fitted(
                state, nil, steps: c.budget?.steps ?? [], length: vectors.meta.budget.labelLength)
            let sent = c.payload.aps.contentState
            #expect(built == sent, "\(c.name)")
            #expect(c.bytes <= (c.budget?.limit ?? vectors.meta.maxBytes), "\(c.name)")
            #expect(c.bytes <= vectors.meta.maxBytes, "\(c.name)")
            ran.append(c.name)
        }
        #expect(ran.count == vectors.cases.count)
    }

    @Test func startsCarryTheAttributes() throws {
        let vectors = try Self.load()
        let starts = vectors.cases.filter { $0.event == "start" }
        #expect(starts.count == 5)
        for c in starts {
            let sent = try #require(c.payload.aps.attributes, "\(c.name)")
            let type = c.payload.aps.attributesType
            #expect(type == "RunActivityAttributes")
            let topicId = try #require(UUID(uuidString: sent.topicId))
            let attributes = RunActivityContent.attributes(
                serverId: sent.serverId, topicId: topicId, topicName: c.topicName)
            let (_, built) = Self.fitted(
                c.payload.aps.contentState, attributes, steps: c.budget?.steps ?? [],
                length: vectors.meta.budget.labelLength)
            #expect(built == sent, "\(c.name)")
            let length = sent.topicName.unicodeScalars.count
            #expect(length <= RunActivityContent.maxLabelLength)
        }
    }

    /// What the app encodes is the server's content state: every key, nulls included, with the
    /// same values (no field renamed, dropped or added).
    @Test func contentStateRoundTrips() throws {
        let raw = try #require(
            try JSONSerialization.jsonObject(with: Fixtures.data(Self.file)) as? [String: Any])
        let cases = try #require(raw["cases"] as? [[String: Any]])
        let decoded = try Self.load().cases
        #expect(cases.count == decoded.count)
        for (object, c) in zip(cases, decoded) {
            let payload = try #require(object["payload"] as? [String: Any])
            let aps = try #require(payload["aps"] as? [String: Any])
            let sentJSON = try #require(aps["content-state"] as? NSDictionary)
            let sent = c.payload.aps.contentState
            let data = try JSONEncoder().encode(sent)
            let again = try JSONDecoder().decode(RunActivityState.self, from: data)
            #expect(again == sent, "\(c.name)")
            let encoded = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
            #expect(Set(encoded.allKeys as? [String] ?? []) == Set(sentJSON.allKeys as? [String] ?? []), "\(c.name)")
            #expect(encoded == sentJSON, "\(c.name)")
        }
    }

    /// The timers2.md §8.1 fields, as the server fills them.
    @Test func lapAndAlertFields() throws {
        let t0 = try #require(RunInstant.parse("2026-10-23T08:00:00Z"))
        let lap = try Self.state("update_tiktok_lap")
        #expect(lap.lapType == "run")
        #expect(lap.lapCount == 2)
        #expect(lap.nextLabel == "Rest")
        #expect(lap.stepIndex == nil)
        #expect(lap.alertAt == RunActivityContent.seconds(t0) + 120 + 900)
        #expect(lap.alertLabel == "Time")

        let paused = try Self.state("update_alert_paused")
        #expect(paused.alertAt == nil)
        #expect(paused.alertLabel == nil)

        let pending = try Self.state("update_alert_pending")
        #expect(pending.alertAt == RunActivityContent.seconds(t0) + 300 + 450)

        let reopened = try Self.state("update_reopened")
        #expect(reopened.pausedMsInSeg == 100_000)
        #expect(reopened.alertAt == RunActivityContent.seconds(t0) + 60 + 100 + 600)
    }

    /// A v1 push (no timers2 fields) still decodes, and a local state never carries a server-only
    /// key it didn't set: `steps_unknown` stays out unless set.
    @Test func aV1PushDecodes() throws {
        let v1 = """
            {"v":1,"run_id":"r","revision":1,"status":"running","started_at":1,"seg":0,"seg_started_at":1,
             "label":"Lap 1","step_index":null,"step_count":0,"next_label":null,"paused_at":null,
             "paused_ms_before_seg":0,"paused_ms_in_seg":0,"ended_at":null,"active_ms":null}
            """
        let state = try JSONDecoder().decode(RunActivityState.self, from: Data(v1.utf8))
        #expect(state.lapType == nil)
        #expect(state.lapCount == nil)
        #expect(state.alertAt == nil)
        #expect(state.alertLabel == nil)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(encoded["steps_unknown"] == nil)
        #expect(encoded["alert_at"] is NSNull)
    }

    /// The local fold fills `alert_at` from active time, and leaves it nil without an instant.
    @Test func localStateAlertFollowsActiveTime() throws {
        let vectors = try Self.load()
        let timer = try #require(vectors.timerSets["tiktok"])
        let start = RunEvent(id: "r", type: .start, at: 0)
        let pause = RunEvent(id: "p", type: .pause, at: 100_000)
        let resume = RunEvent(id: "q", type: .resume, at: 220_000, pauseId: "p")
        func content(_ events: [RunEvent], now: Int?) throws -> RunActivityState {
            let folded = try RunFold.fold(runId: "r", timer: timer, events: events)
            return RunActivityContent.state(
                runId: "r", revision: 1, status: folded.status, state: folded, timer: timer, now: now)
        }
        let before = try content([start], now: 10_000)
        #expect(before.alertAt == 450)
        #expect(before.alertLabel == "Half way")
        #expect(try content([start, pause], now: 200_000).alertAt == nil)
        #expect(try content([start, pause, resume], now: 230_000).alertAt == 450 + 120)
        #expect(try content([start], now: 450_000).alertLabel == "Time")
        #expect(try content([start], now: 900_000).alertAt == nil)
        #expect(try content([start], now: nil).alertAt == nil)
    }

    /// timers2.md §8.1: in a lap, `next_label` is the next lap's type label (nil when laps are
    /// untyped), never the pending step's; in a step it is the next step's (#208).
    @Test func nextLabelInALapIsNeverThePendingStep() throws {
        let vectors = try Self.load()
        func content(_ set: String, _ events: [RunEvent]) throws -> RunActivityState {
            let timer = try #require(vectors.timerSets[set])
            let all = [RunEvent(id: "r", type: .start, at: 0)] + events
            let folded = try RunFold.fold(runId: "r", timer: timer, events: all)
            return RunActivityContent.state(
                runId: "r", revision: 1, status: folded.status, state: folded, timer: timer, now: nil)
        }
        let lap = RunEvent(id: "l", type: .lap, at: 60_000, seg: 0)
        let inStep = try content("steps_and_laps", [])
        #expect(inStep.label == "Warmup")
        #expect(inStep.nextLabel == "Cooldown")
        let typed = try content("steps_and_laps", [lap])
        #expect(typed.label == "Run 1")
        #expect(typed.nextLabel == "Rest", "the next lap's type, not the pending Cooldown")
        let untyped = try content("three", [lap])
        #expect(untyped.label == "Lap 1")
        #expect(untyped.lapType == nil)
        #expect(untyped.nextLabel == nil, "untyped laps: nil, not the pending Breakfast")
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
