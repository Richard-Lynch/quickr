#if DEBUG
import Foundation
import QuickrCore
import QuickrData

/// The UI-test fake server's runs (timers.md §3–§4, timers2.md §3–§4), like `services/runs.py` and
/// QuickrDataTests' `FakeServer+Runs`: each run's events in arrival order, folded with the real
/// `RunFold` (v4, the version's lap types included) after every event. A stop makes the entry
/// unless the version has a required question and the stop carried no answers (the run is then
/// `finishing`); `finish` and a finishing run's discard are decided outside the fold (§3.6, §3.7).
/// A start for a topic with an open run is merged into it (§4.5). A reopen while the topic has
/// another open run is 409 `conflict`; a re-stop updates the entry (revision + 1); a discard that
/// reverts the reopen of a run with no entry discards it (timers2.md §4.1). An event already
/// recorded answers its stored result again. Another device's reopen or remove can be scripted
/// (`FakeServerState.reopenElsewhere`, `removeElsewhere`, UITestLaunch.swift).
enum FakeRuns {
    /// `POST /api/v1/runs/{run_id}/events`.
    static func record(_ pathId: String, _ request: HTTPRequest, state: FakeServerState, headers: HTTPHeaders)
        -> HTTPResponse
    {
        func problem(_ status: Int, _ code: String, _ detail: String, errors: [[String: Any]] = []) -> HTTPResponse {
            let object: [String: Any] = ["code": code, "detail": detail, "errors": errors]
            return HTTPResponse(
                status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        guard let data = request.body, let body = try? WireCoding.decoder().decode(RunEventInDTO.self, from: data),
            let type = RunEventType(rawValue: body.type), let at = RunInstant.parse(body.at)
        else { return problem(422, "invalid_request", "bad body") }
        // The answers as sent, for the entry's echo (`FakeServer.echo`).
        let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["answers"] as? [String: Any]
        let answers = raw?.compactMapValues { $0 is NSNull ? nil : $0 }
        // A start's topic, read before the runs are locked (they share the server state's lock).
        let topic = type == .start ? body.topicId.flatMap(state.topic) : nil
        let event = RunEvent(
            id: body.id.lowercased(), type: type, at: at, seg: body.seg, step: body.step,
            pauseId: body.pauseId?.lowercased(), target: body.target?.lowercased())
        let outcome = state.recordRun { book in
            book.record(event, body: body, answers: answers, path: pathId.lowercased(), topic: topic)
        }
        switch outcome.result {
        case .answer(let status, let json):
            return HTTPResponse(status: status, headers: headers, body: json)
        case .problem(let status, let code, let detail, let missing):
            let errors = missing.map {
                ["loc": ["answers", $0], "message": "This question is required"] as [String: Any]
            }
            return problem(status, code, detail, errors: errors)
        }
    }
}

/// What a run event did: the response, and the entry JSON (`EntryOut`) to log in the feed when the
/// event made or changed one.
struct FakeRunOutcome: Sendable {
    enum Result: Sendable {
        case answer(status: Int, json: Data)
        /// A refusal; `missing` are required question keys (422 `invalid_answers`).
        case problem(status: Int, code: String, detail: String, missing: [String] = [])
    }

    var result: Result
    var feedEntry: String?
}

/// The runs on the fake server, by id, and the ids merged into them.
struct FakeRunBook: Sendable {
    var runs: [String: FakeServerRun] = [:]
    var aliases: [String: String] = [:]

    mutating func record(
        _ event: RunEvent, body: RunEventInDTO, answers: [String: Any]?, path: String, topic: [String: Any]?
    ) -> FakeRunOutcome {
        let answersJSON = answers.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let target = aliases[path] ?? path
        if var run = runs[target] {
            // A replay answers the stored result.
            if run.bodies[event.id] != nil { return run.outcome(event.id, status: 200, entryChanged: false) }
            guard event.type != .start else {
                return FakeRunOutcome(
                    result: .problem(status: 409, code: "event_conflict", detail: "a start of another run"))
            }
            if event.type == .reopen,
                runs.values.contains(where: { $0.id != run.id && $0.topicId == run.topicId && $0.status.isOpen })
            {
                // timers2.md §4.2 (A15): nothing stored.
                return FakeRunOutcome(
                    result: .problem(status: 409, code: "conflict", detail: "the topic has another open run"))
            }
            let before = run.entry
            switch (event.type, run.status) {
            case (.finish, .running), (.finish, .paused):
                return FakeRunOutcome(result: .problem(status: 409, code: "run_open", detail: "stop the run first"))
            case (.finish, .finishing):
                let missing = run.required.filter { answers?[$0] == nil }
                if !missing.isEmpty {
                    return FakeRunOutcome(
                        result: .problem(
                            status: 422, code: "invalid_answers", detail: "one or more answers are invalid",
                            missing: missing))
                }
                run.append(event, body, answers: answersJSON)
                run.decided[event.id] = .applied
                run.decidedStatus = .stopped
            case (.finish, .stopped):
                run.append(event, body, answers: answersJSON)
                run.decided[event.id] = .applied
                run.entry?.merge(answers: answers ?? [:], notes: body.notes)
            case (.finish, _):
                run.append(event, body, answers: answersJSON)
                run.decided[event.id] = .void(.alreadyClosed)
            case (.discard, .finishing):
                run.append(event, body, answers: answersJSON)
                run.decided[event.id] = .applied
                run.decidedStatus = .discarded
            case (.stop, _) where answers != nil && run.status.isOpen:
                let missing = run.required.filter { answers?[$0] == nil }
                if !missing.isEmpty {
                    return FakeRunOutcome(
                        result: .problem(
                            status: 422, code: "invalid_answers", detail: "one or more answers are invalid",
                            missing: missing))
                }
                run.append(event, body, answers: answersJSON)
            default:
                run.append(event, body, answers: answersJSON)
            }
            run.refold()
            runs[target] = run
            return run.outcome(event.id, status: 200, entryChanged: run.entry != before)
        }

        guard event.type == .start else {
            return FakeRunOutcome(result: .problem(status: 404, code: "not_found", detail: "run not found"))
        }
        guard event.id == path else {
            return FakeRunOutcome(
                result: .problem(status: 422, code: "invalid_request", detail: "a start's id is its run's"))
        }
        guard let topic, let topicId = (topic["id"] as? String).flatMap(UUID.init(uuidString:)) else {
            return FakeRunOutcome(result: .problem(status: 404, code: "not_found", detail: "topic not found"))
        }
        if topic["status"] as? String == "archived" {
            return FakeRunOutcome(result: .problem(status: 409, code: "topic_archived", detail: "topic is archived"))
        }
        // The topic's current version's timer and questions (the fake server keeps no older ones).
        guard let version = body.version, let timer = Self.timer(topic["timer"]) else {
            return FakeRunOutcome(result: .problem(status: 409, code: "topic_not_timed", detail: "not timed"))
        }
        if let openId = runs.values.first(where: { $0.topicId == topicId && $0.status.isOpen })?.id,
            var open = runs[openId]
        {
            // §4.5: merged into the open run, whose start is kept.
            aliases[path] = open.id
            if let alias = UUID(uuidString: path) { open.aliases.append(alias) }
            open.append(event, body, answers: answersJSON)
            open.refold()
            runs[open.id] = open
            return open.outcome(event.id, status: 201, entryChanged: false)
        }
        let required = ((topic["questions"] as? [[String: Any]]) ?? [])
            .filter { $0["required"] as? Bool ?? true }
            .compactMap { $0["key"] as? String }
        var run = FakeServerRun(
            id: path, topicId: topicId, version: version, timer: timer, required: required,
            state: RunState(
                status: .running, startedAt: event.at, endedAt: nil, open: nil, nextStep: nil, pausedSince: nil,
                segments: [], skipped: [], pauses: [], effects: [:]),
            status: .running, source: body.source ?? "api")
        run.append(event, body, answers: answersJSON)
        run.refold()
        runs[path] = run
        return run.outcome(event.id, status: 201, entryChanged: false)
    }

    /// A `timer` as the topic JSON holds it (steps and lap types); nil when untimed.
    static func timer(_ timer: Any?) -> TopicTimer? {
        guard let timer = timer as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: timer)
        else { return nil }
        return try? JSONDecoder().decode(TopicTimer.self, from: data)
    }

    /// Another device's reopen (of the run's terminal stop) or remove (of `target`) of the run
    /// `runId` routes to, at the server's now (timers2.md §6.2, §6.6). Nil when the run isn't
    /// here. With the run as the feed's item while it is open (the outcome's `feedEntry` holds an
    /// entry the event changed).
    mutating func elsewhere(_ type: RunEventType, runId: String, target: String? = nil) -> (
        outcome: FakeRunOutcome, openRun: [String: Any]?
    )? {
        let path = runId.lowercased()
        guard let run = runs[aliases[path] ?? path] else { return nil }
        let id = UUID().wireString
        let at = max(RunInstant.milliseconds(Date()), (run.events.map(\.event.at).max() ?? 0) + 1)
        let named = type == .reopen ? (target ?? run.state.terminalId) : target
        let body = RunEventInDTO(id: id, type: type.rawValue, at: RunInstant.format(at), target: named)
        let event = RunEvent(id: id, type: type, at: at, target: named?.lowercased())
        let outcome = record(event, body: body, answers: nil, path: path, topic: nil)
        guard let after = runs[aliases[path] ?? path], after.status.isOpen || after.status == .finishing else {
            return (outcome, nil)
        }
        let json = (try? JSONSerialization.jsonObject(with: WireCoding.encoder().encode(RunDTO(after.domain))))
        return (outcome, json as? [String: Any])
    }
}

/// A finished run's entry, as the fake server holds it.
struct FakeRunEntry: Sendable, Equatable {
    var answers: Data
    var notes: String
    var meta: [String: String]
    var revision: Int
    var createdAt: Int
    var updatedAt: Int
    var timing: Timing

    mutating func merge(answers patch: [String: Any], notes: String?) {
        var merged = (try? JSONSerialization.jsonObject(with: answers) as? [String: Any]) ?? [:]
        for (key, value) in patch { merged[key] = value }
        answers = (try? JSONSerialization.data(withJSONObject: merged)) ?? answers
        if let notes { self.notes = notes }
        revision += 1
        updatedAt = RunInstant.milliseconds(Date())
    }
}

/// One run on the fake server.
struct FakeServerRun: Sendable {
    var id: String
    var topicId: UUID
    var version: Int
    /// The version's timer: its steps and lap types (timers2.md §1.1).
    var timer: TopicTimer
    var steps: [TopicTimer.Step] { timer.steps }
    /// The version's required question keys.
    var required: [String]
    var events: [Run.StoredEvent] = []
    /// Each event's request, by lowercase id (a replay answers the stored result), and its answers
    /// as sent (JSON).
    var bodies: [String: RunEventInDTO] = [:]
    var answers: [String: Data] = [:]
    /// Effects decided outside the fold (finish, a finishing run's discard).
    var decided: [String: RunEffect] = [:]
    /// A status decided outside the fold: `stopped` by a finish, `discarded`.
    var decidedStatus: RunStatus?
    var state: RunState
    var status: RunStatus
    var revision = 0
    var aliases: [UUID] = []
    var source: String
    var entry: FakeRunEntry?

    init(
        id: String, topicId: UUID, version: Int, timer: TopicTimer, required: [String], state: RunState,
        status: RunStatus, source: String
    ) {
        self.id = id
        self.topicId = topicId
        self.version = version
        self.timer = timer
        self.required = required
        self.state = state
        self.status = status
        self.source = source
    }

    var domain: Run {
        let effects = state.effects.merging(decided) { $1 }
        return Run(
            id: UUID(uuidString: id)!, topicId: topicId, version: version, status: status, revision: revision,
            startedAt: state.startedAt, endedAt: state.endedAt, edited: false,
            events: events.map { stored in
                var stored = stored
                stored.effect = effects[stored.event.id] ?? .applied
                return stored
            },
            state: RunState(
                status: status, startedAt: state.startedAt, endedAt: state.endedAt, open: state.open,
                nextStep: state.nextStep, pausedSince: state.pausedSince, segments: state.segments,
                skipped: state.skipped, pauses: state.pauses, effects: effects,
                terminalId: status == .discarded ? nil : state.terminalId, nextLapType: state.nextLapType,
                lapCount: state.lapCount, reopenId: state.reopenId),
            aliases: aliases)
    }

    mutating func append(_ event: RunEvent, _ body: RunEventInDTO, answers: Data?) {
        events.append(Run.StoredEvent(event: event, arrival: events.count + 1, effect: .applied, source: source))
        bodies[event.id] = body
        if let answers { self.answers[event.id] = answers }
        revision += 1
    }

    /// The fold of every event, then the server's status (§3.5), and the entry once stopped. A
    /// reopen clears a decided status; a discard reverting the reopen of a run with no entry
    /// discards it (timers2.md §4.1).
    mutating func refold() {
        guard let folded = try? RunFold.fold(runId: id, timer: timer, events: events.map(\.event)) else { return }
        let reverted = events.contains { $0.event.type == .reopen && folded.effects[$0.event.id] == .void(.reverted) }
        if folded.status.isOpen {
            decidedStatus = nil
        } else if reverted, folded.status == .stopped, entry == nil, decidedStatus == nil {
            decidedStatus = .discarded
        }
        state = folded
        if let decidedStatus {
            status = decidedStatus
        } else if folded.status == .stopped {
            let stop = events.first { $0.event.id == folded.terminalId }
            let stopAnswers = stop.flatMap { answers[$0.event.id] }
            status = entry != nil || stopAnswers != nil || required.isEmpty ? .stopped : .finishing
        } else {
            status = folded.status
        }
        guard status == .stopped, let timing = try? RunFold.projectTiming(folded, steps: steps) else { return }
        guard var entry else {
            // The finish's answers and notes, else the stop's (§3.5, §3.6).
            let finish = events.last { $0.event.type == .finish }?.event.id
            let stop = events.first { $0.event.type == .stop }?.event.id
            let carrier = finish ?? stop
            let now = RunInstant.milliseconds(Date())
            self.entry = FakeRunEntry(
                answers: carrier.flatMap { answers[$0] } ?? Data("{}".utf8),
                notes: carrier.flatMap { bodies[$0]?.notes } ?? "", meta: carrier.flatMap { bodies[$0]?.meta } ?? [:],
                revision: 1, createdAt: now, updatedAt: now, timing: timing)
            return
        }
        if entry.timing != timing {
            entry.timing = timing
            entry.revision += 1
            self.entry = entry
        }
    }

    /// The `RunEventResult` for `eventId`, with the entry (`EntryOut`) while the run is stopped.
    func outcome(_ eventId: String, status: Int, entryChanged: Bool) -> FakeRunOutcome {
        let effect = decided[eventId] ?? state.effects[eventId] ?? .applied
        let reason: Any = effect.reason.map { $0.rawValue as Any } ?? NSNull()
        let entryJSON = self.status == .stopped ? entry.map(entryObject) : nil
        let json: [String: Any] = [
            "event": ["id": eventId, "effect": effect == .applied ? "applied" : "void", "reason": reason],
            "run": (try? JSONSerialization.jsonObject(with: WireCoding.encoder().encode(RunDTO(domain)))) ?? [:],
            "entry": entryJSON ?? NSNull(),
        ]
        let feedEntry =
            entryChanged
            ? entryJSON.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map {
                String(decoding: $0, as: UTF8.self)
            } : nil
        return FakeRunOutcome(
            result: .answer(status: status, json: (try? JSONSerialization.data(withJSONObject: json)) ?? Data()),
            feedEntry: feedEntry)
    }

    /// `EntryOut`: id = run id, `captured_at` = the run's end (T1), and its timing.
    private func entryObject(_ entry: FakeRunEntry) -> [String: Any] {
        let answers = (try? JSONSerialization.jsonObject(with: entry.answers) as? [String: Any]) ?? [:]
        let timing =
            (try? JSONSerialization.jsonObject(with: WireCoding.encoder().encode(TimingDTO(entry.timing)))) ?? NSNull()
        return [
            "id": id, "topic_id": topicId.wireString, "version": version, "revision": entry.revision,
            "source": source, "channel": "ios", "captured_at": RunInstant.format(entry.timing.endedAt),
            "created_at": RunInstant.format(entry.createdAt), "updated_at": RunInstant.format(entry.updatedAt),
            "notes": entry.notes, "meta": entry.meta, "answers": FakeServer.echo(answers), "timing": timing,
        ]
    }
}
#endif
