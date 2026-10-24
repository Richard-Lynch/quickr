import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Runs on the outbox harness: a timed version of `T` here and on the fake server, the façade,
/// and reads of the local view.
extension OutboxHarness {
    static let steps = [
        TopicTimer.Step(key: "shower", label: "Shower"), TopicTimer.Step(key: "breakfast", label: "Breakfast"),
        TopicTimer.Step(key: "out", label: "Out"),
    ]

    /// Makes `version` of the topic timed with `steps`, on the server and in the local server layer.
    /// `requiresAnswers`: the version keeps the required "mood" question, so a stop without answers
    /// leaves the run finishing.
    func timed(version: Int = 1, steps: [TopicTimer.Step] = steps, requiresAnswers: Bool = false) throws {
        server.time(topic.id, version: version, FakeTimer(steps: steps, requiresAnswers: requiresAnswers))
        let questions = Make.questions.map { question in
            var question = question
            if !requiresAnswers { question.required = false }
            return question
        }
        let row = TopicVersion(
            version: version, questions: questions, timer: TopicTimer(steps: steps), createdAt: Make.t0)
        let topicId = topic.id
        try write { db in _ = try ServerLayer.insert(db, version: row, id: UUID(), topicId: topicId) }
    }

    /// The façade of one process, on this harness's store (or another process's).
    func runs(_ origin: OutboxOrigin = .app, store: LocalStore? = nil) -> RunWrites {
        RunWrites(store: store ?? self.store, origin: origin)
    }

    func localRuns() throws -> [LocalRun] { try read { db in try RunOverlay.localRuns(db) } }

    func localRun(_ id: String) throws -> LocalRun? { try read { db in try RunOverlay.localRun(db, id: id) } }

    var runItems: [OutboxItem] { get throws { try items.filter { $0.kind == .runEvent } } }

    /// The `run.event` payload of an item.
    func payload(_ item: OutboxItem) throws -> RunEventPayload { try #require(try item.runEventPayload()) }

    /// A `run.event` item's `at`, epoch milliseconds.
    func at(_ item: OutboxItem) throws -> Int { try #require(RunInstant.parse(try payload(item).event.at)) }

    /// Starts a run of `T` (version 1) through the façade; returns its id.
    @discardableResult
    func start(_ writes: RunWrites? = nil, id: UUID? = nil) async throws -> String {
        let result = try await (writes ?? runs()).start(topic: ref, version: 1, id: id)
        return result.runId
    }

    /// A server run of `T`, as the feed would have stored it: started at `Make.t0` by another
    /// device, with `events` after its start.
    @discardableResult
    func seedServerRun(id: UUID = UUID(), steps: [TopicTimer.Step] = steps, events: [RunEvent] = []) throws -> Run {
        let start = RunEvent(id: id.wireString, type: .start, at: RunInstant.milliseconds(Make.t0))
        let all = [start] + events
        let state = try RunFold.fold(runId: id.wireString, steps: steps, events: all)
        let run = Run(
            id: id, topicId: topic.id, version: 1, status: state.status, revision: all.count,
            startedAt: state.startedAt, endedAt: state.endedAt, edited: false,
            events: all.enumerated().map { index, event in
                Run.StoredEvent(
                    event: event, arrival: index + 1, effect: state.effects[event.id.lowercased()] ?? .applied,
                    source: "web")
            },
            state: state, aliases: [])
        try write { db in _ = try ServerLayer.upsert(db, run: run) }
        return run
    }
}

/// Epoch milliseconds of `Make.t0` plus `seconds`.
func ms(_ seconds: Double = 0) -> Int { RunInstant.milliseconds(Make.t0.addingTimeInterval(seconds)) }
