import Foundation
import QuickrCore
import QuickrData

/// A timed version on the fake server: its steps, and whether it has a required question.
struct FakeTimer: Sendable {
    var steps: [TopicTimer.Step]
    var requiresAnswers = false
}

/// A run on the fake server: its events in arrival order, folded with the real `RunFold` after
/// every event, as `services/runs.py` does (timers.md §3–§4). `finish` and a finishing run's
/// discard are decided outside the fold (§3.6, §3.7).
struct FakeRun: Sendable {
    var id: String
    var topicId: UUID
    var version: Int
    var timer: FakeTimer
    var events: [Run.StoredEvent] = []
    /// The request of each event, by lowercase id: a replay answers the stored result.
    var bodies: [String: RunEventInDTO] = [:]
    /// Effects decided outside the fold (finish, a finishing run's discard).
    var decided: [String: RunEffect] = [:]
    /// A status decided outside the fold: `stopped` by a finish, `discarded`.
    var decidedStatus: RunStatus?
    var state: RunState
    var status: RunStatus
    var revision = 0
    var aliases: [UUID] = []
    var source: String
    var entry: Entry?

    var domain: Run {
        let effects = state.effects.merging(decided) { $1 }
        return Run(
            id: UUID(uuidString: id)!, topicId: topicId, version: version, status: status, revision: revision,
            startedAt: state.startedAt, endedAt: state.endedAt, edited: false,
            events: events.map { stored in
                var stored = stored
                stored.effect = effects[stored.event.id.lowercased()] ?? .applied
                return stored
            },
            state: RunState(
                status: status, startedAt: state.startedAt, endedAt: state.endedAt, open: state.open,
                nextStep: state.nextStep, pausedSince: state.pausedSince, segments: state.segments,
                skipped: state.skipped, pauses: state.pauses, effects: effects),
            aliases: aliases)
    }

    func effect(of eventId: String) -> RunEffect {
        decided[eventId] ?? state.effects[eventId] ?? .applied
    }
}

extension FakeServer {
    /// Makes `version` of `topicId` timed.
    func time(_ topicId: UUID, version: Int = 1, _ timer: FakeTimer) {
        with { $0.timers["\(topicId.wireString)#\(version)"] = timer }
    }

    func run(_ id: String) -> FakeRun? { with { $0.runs[$0.runAliases[id] ?? id] } }

    /// `POST /runs/{run_id}/events` (timers.md §3.2–§3.7).
    static func recordRunEvent(_ pathId: String, _ request: HTTPRequest, _ state: inout State) -> HTTPResponse {
        guard let data = request.body, let body = try? WireCoding.decoder().decode(RunEventInDTO.self, from: data),
            let type = RunEventType(rawValue: body.type), let at = RunInstant.parse(body.at)
        else { return problem(422, "invalid_request", "bad body") }
        let path = pathId.lowercased()
        let eventId = body.id.lowercased()
        if state.deletedRuns.contains(path) { return problem(409, "run_deleted", "the run's topic was deleted") }
        let target = state.runAliases[path] ?? path
        let event = RunEvent(
            id: eventId, type: type, at: at, seg: body.seg, step: body.step, pauseId: body.pauseId?.lowercased())

        if var run = state.runs[target] {
            if let stored = run.bodies[eventId] {
                // A replay, unless the content differs (as `_replay` compares it).
                let same =
                    stored.type == body.type && RunInstant.parse(stored.at) == at && stored.seg == body.seg
                    && stored.step == body.step && stored.pauseId?.lowercased() == body.pauseId?.lowercased()
                    && (type != .start || body.topicId?.lowercased() == run.topicId.wireString)
                guard same else {
                    return problem(409, "event_conflict", "already recorded with different content")
                }
                return result(run, eventId, status: 200, state)
            }
            guard type != .start else { return problem(409, "event_conflict", "a start of another run") }
            switch (type, run.status) {
            case (.finish, .running), (.finish, .paused):
                return problem(409, "run_open", "stop the run first")
            case (.finish, .finishing):
                run.append(event, body)
                run.decided[eventId] = .applied
                run.decidedStatus = .stopped
            case (.finish, .stopped):
                run.append(event, body)
                run.decided[eventId] = .applied
                for (key, value) in body.answers ?? [:] { run.entry?.answers[key] = value?.value }
                if let notes = body.notes { run.entry?.notes = notes }
                run.entry?.revision += 1
            case (.finish, _):
                run.append(event, body)
                run.decided[eventId] = .void(.alreadyClosed)
            case (.discard, .finishing):
                run.append(event, body)
                run.decided[eventId] = .applied
                run.decidedStatus = .discarded
            default:
                run.append(event, body)
            }
            run.refold()
            state.runs[target] = run
            return result(run, eventId, status: 200, state)
        }

        guard type == .start else { return problem(404, "not_found", "run not found") }
        guard eventId == path else { return problem(422, "invalid_request", "a start's id is its run's") }
        if state.entries[path] != nil || state.deleted.contains(path) {
            return problem(409, "id_conflict", "the id of an entry")
        }
        guard let topicId = body.topicId, let topic = state.topics[topicId] else {
            return problem(404, "not_found", "topic not found")
        }
        if topic.status == .archived { return problem(409, "topic_archived", "topic is archived") }
        guard let version = body.version, let timer = state.timers["\(topicId)#\(version)"] else {
            return problem(409, "topic_not_timed", "not timed")
        }
        if let open = state.runs.values.first(where: { $0.topicId == topic.id && $0.status.isOpen }) {
            // §4.5: merged into the open run, whose start is kept.
            var run = open
            state.runAliases[path] = run.id
            run.aliases.append(UUID(uuidString: path)!)
            run.append(event, body)
            run.refold()
            state.runs[run.id] = run
            return result(run, eventId, status: 201, state)
        }
        let started = RunState(
            status: .running, startedAt: at, endedAt: nil, open: nil, nextStep: nil, pausedSince: nil, segments: [],
            skipped: [], pauses: [], effects: [:])
        var run = FakeRun(
            id: path, topicId: topic.id, version: version, timer: timer, state: started, status: .running,
            source: body.source ?? "api")
        run.append(event, body)
        run.refold()
        state.runs[path] = run
        return result(run, eventId, status: 201, state)
    }

    /// `GET /runs/{run_id}`: the run an id or alias resolves to, in any status.
    static func getRun(_ pathId: String, _ state: State) -> HTTPResponse {
        let path = pathId.lowercased()
        guard let run = state.runs[state.runAliases[path] ?? path] else { return problem(404, "not_found", "no run") }
        let body = try! WireCoding.encoder().encode(RunDTO(run.domain))
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private static func result(_ run: FakeRun, _ eventId: String, status: Int, _ state: State) -> HTTPResponse {
        let wire = RunWire(run.effect(of: eventId))
        var json: [String: Any] = [
            "event": ["id": eventId, "effect": wire.effect, "reason": wire.reason.map { $0 as Any } ?? NSNull()],
            "run": try! JSONSerialization.jsonObject(with: WireCoding.encoder().encode(RunDTO(run.domain))),
            "entry": NSNull(),
        ]
        if let entry = run.entry, run.status == .stopped {
            json["entry"] = try! JSONSerialization.jsonObject(with: entryJSON(entry))
        }
        let body = try! JSONSerialization.data(withJSONObject: json)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

private struct RunWire {
    var effect: String
    var reason: String?

    init(_ effect: RunEffect) {
        switch effect {
        case .applied: (self.effect, reason) = ("applied", nil)
        case .void(let reason): (self.effect, self.reason) = ("void", reason.rawValue)
        }
    }
}

extension FakeRun {
    mutating func append(_ event: RunEvent, _ body: RunEventInDTO) {
        events.append(Run.StoredEvent(event: event, arrival: events.count + 1, effect: .applied, source: source))
        bodies[event.id] = body
        revision += 1
    }

    /// The fold of every event, then the server's status (§3.5): a stop makes the entry unless the
    /// version has a required question and the stop carried no answers (finishing).
    mutating func refold() {
        guard let folded = try? RunFold.fold(runId: id, steps: timer.steps, events: events.map(\.event)) else { return }
        state = folded
        if let decidedStatus {
            status = decidedStatus
        } else if folded.status == .stopped {
            let stop = events.first { $0.event.type == .stop && folded.effects[$0.event.id] == .applied }
            let stopAnswers = stop.flatMap { bodies[$0.event.id]?.answers }
            status = entry != nil || stopAnswers != nil || !timer.requiresAnswers ? .stopped : .finishing
        } else {
            status = folded.status
        }
        guard status == .stopped, let endedAt = folded.endedAt,
            let timing = try? RunFold.projectTiming(folded, steps: timer.steps)
        else { return }
        if entry == nil {
            let finish = events.last { $0.event.type == .finish }.flatMap { bodies[$0.event.id] }
            let stop = events.first { $0.event.type == .stop }.flatMap { bodies[$0.event.id] }
            let carrier = finish ?? stop
            let at = RunInstant.date(endedAt)
            entry = Entry(
                id: UUID(uuidString: id)!, topicId: topicId, version: version, revision: 1, source: source,
                channel: .ios, capturedAt: at, createdAt: at, updatedAt: at, notes: carrier?.notes ?? "",
                meta: carrier?.meta ?? [:], answers: (carrier?.answers ?? [:]).compactMapValues { $0?.value },
                timing: timing)
        } else if entry?.timing != timing {
            entry?.timing = timing
            entry?.revision += 1
        }
    }
}
