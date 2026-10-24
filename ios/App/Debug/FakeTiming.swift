#if DEBUG
import Foundation
import QuickrCore
import QuickrData
import Synchronization

/// `-QuickrSeedTimedTopic` (I-MANAGE's UI tests, timers.md §3.8, §9): the fake server also has a
/// timed topic, "Morning" (steps Shower and Dress, no questions), with one finished run logged
/// yesterday: Shower 4:00, then Dress 5:00. It answers Edit times (`PATCH /entries/{id}` with
/// `timing`, rebuilt as the backend's `edited_timing` does, checked against `expected_revision`),
/// `GET /entries/{id}`, and the topic's stats and timing stats (`TimingStats`, the backend's port).
enum FakeTiming {
    static let flag = "-QuickrSeedTimedTopic"
    static let morningId = UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!
    static let entryId = UUID(uuidString: "00000000-0000-4000-8000-0000000000e3")!
    static let steps = [TopicTimer.Step(key: "shower", label: "Shower"), TopicTimer.Step(key: "dress", label: "Dress")]

    static var isEnabled: Bool {
        UITestLaunch.isActive && ProcessInfo.processInfo.arguments.contains(flag)
    }

    private struct State {
        var revision = 1
        var timing: Timing
    }

    private static let state = Mutex(State(timing: seededTiming()))

    /// Yesterday 07:00 (UTC): Shower to 07:04, Dress to 07:09.
    static func seededTiming(now: Date = Date()) -> Timing {
        let day = RunInstant.milliseconds(now) / 86_400_000 - 1  // after 1970: truncation is floor
        let start = day * 86_400_000 + 7 * 3_600_000
        let shower = start + 4 * 60_000
        let end = shower + 5 * 60_000
        return TimingDraft.Edit(
            startedAt: start,
            segments: [
                .init(kind: .step, step: "shower", endedAt: shower), .init(kind: .step, step: "dress", endedAt: end),
            ],
            skipped: [], pauses: []
        ).timing(steps: steps)
    }

    static let stepsJSON = #"{"steps": [{"key": "shower", "label": "Shower"}, {"key": "dress", "label": "Dress"}]}"#

    /// The topic as `TopicDetail`.
    static var topicDetail: [String: Any] {
        [
            "archived_at": NSNull(), "created_at": "2026-01-01T00:00:00Z", "current_version": 1, "description": "",
            "due": NSNull(), "entry_count": 1, "id": morningId.wireString, "last_captured_at": NSNull(),
            "name": "Morning", "question_count": 0, "questions": [Any](), "revision": 1, "schedule": NSNull(),
            "schedule_updated_at": NSNull(), "slug": "morning", "status": "active",
            "timer": (try? JSONSerialization.jsonObject(with: Data(stepsJSON.utf8))) ?? NSNull(),
            "updated_at": "2026-01-01T00:00:00Z",
        ]
    }

    /// The feed items the server starts with: the topic's version, the topic and the run's entry.
    static func seedFeed() -> [String] {
        guard isEnabled else { return [] }
        let version: [String: Any] = [
            "kind": "version", "seq": 5, "id": "00000000-0000-4000-8000-0000000000d3",
            "topic_id": morningId.wireString,
            "version": [
                "change_note": "", "created_at": "2026-01-01T00:00:00Z", "entry_count": 0, "questions": [Any](),
                "timer": topicDetail["timer"] ?? NSNull(), "version": 1,
            ] as [String: Any],
        ]
        let topic: [String: Any] = ["kind": "topic", "seq": 6, "topic": topicDetail]
        let entry: [String: Any] = ["kind": "entry", "seq": 7, "entry": entryJSON()]
        return [version, topic, entry].compactMap(json)
    }

    static func seedTopics() -> [String: Data] {
        guard isEnabled, let data = try? JSONSerialization.data(withJSONObject: topicDetail) else { return [:] }
        return [morningId.wireString: data]
    }

    /// The run's entry as `EntryOut`.
    static func entryJSON() -> [String: Any] {
        let (revision, timing) = state.withLock { ($0.revision, $0.timing) }
        let end = RunInstant.format(timing.endedAt)
        return [
            "id": entryId.wireString, "topic_id": morningId.wireString, "version": 1, "revision": revision,
            "source": "ios", "channel": "ios", "captured_at": end, "created_at": end, "updated_at": end, "notes": "",
            "meta": [String: String](), "answers": [Any](), "timing": timingJSON(timing),
        ]
    }

    static func timingJSON(_ t: Timing) -> [String: Any] {
        [
            "started_at": RunInstant.format(t.startedAt), "ended_at": RunInstant.format(t.endedAt),
            "active_ms": t.activeMs, "paused_ms": t.pausedMs, "complete": t.complete, "edited": t.edited,
            "segments": t.segments.map { s -> [String: Any] in
                [
                    "kind": s.kind.rawValue, "step": s.step ?? NSNull(), "label": s.label,
                    "started_at": RunInstant.format(s.startedAt), "ended_at": RunInstant.format(s.endedAt),
                    "active_ms": s.activeMs, "paused_ms": s.pausedMs,
                ]
            },
            "skipped": t.skipped,
            "pauses": t.pauses.map { ["start": RunInstant.format($0.start), "end": RunInstant.format($0.end)] },
        ]
    }

    private static func json(_ object: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func data(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    /// Its routes, or nil for any other request. `appendToFeed` puts an edited entry in the feed.
    static func route(
        _ request: HTTPRequest, headers: HTTPHeaders, appendToFeed: (_ kind: String, _ key: String, Any) -> Void
    ) -> HTTPResponse? {
        guard isEnabled else { return nil }
        let path = request.url.path()
        let entryPath = "/api/v1/entries/\(entryId.wireString)"
        func problem(_ status: Int, _ code: String, _ detail: String, loc: [Any]? = nil) -> HTTPResponse {
            let errors: [[String: Any]] = loc.map { [["loc": $0, "message": detail]] } ?? []
            return HTTPResponse(
                status: status, headers: headers, body: data(["code": code, "detail": detail, "errors": errors]))
        }
        if path == entryPath, request.method == .get {
            return HTTPResponse(status: 200, headers: headers, body: data(entryJSON()))
        }
        if path == entryPath, request.method == .patch {
            guard let body = request.body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                let edit = edit(body["timing"])
            else { return problem(422, "invalid_request", "timing is required") }
            if body["captured_at"] != nil {
                return problem(422, "invalid_request", "timing and captured_at together", loc: ["body", "captured_at"])
            }
            let current = state.withLock { $0.revision }
            guard body["expected_revision"] as? Int == current else {
                return problem(409, "stale_revision", "the entry changed: revision is \(current)")
            }
            let timing = edit.timing(steps: steps)
            state.withLock {
                $0.revision += 1
                $0.timing = timing
            }
            let entry = entryJSON()
            appendToFeed("entry", "entry", entry)
            return HTTPResponse(status: 200, headers: headers, body: data(entry))
        }
        let parts = path.split(separator: "/").map(String.init)  // api v1 topics {ref} stats|timing
        guard parts.count == 5, parts[2] == "topics", parts[3] == "morning" || parts[3] == morningId.wireString,
            request.method == .get
        else { return nil }
        let timing = state.withLock { $0.timing }
        switch parts[4] {
        case "stats":
            let end = RunInstant.format(timing.endedAt)
            return HTTPResponse(
                status: 200, headers: headers,
                body: data([
                    "topic_id": morningId.wireString, "entry_count": 1, "first_captured_at": end,
                    "last_captured_at": end, "sources": [["value": "ios", "count": 1]], "questions": [Any](),
                ]))
        case "timing":
            let stats = TimingStats.compute(
                [.init(entryId: entryId.wireString, capturedAt: timing.endedAt, timing: timing)], versions: [1: steps],
                currentVersion: 1)
            return HTTPResponse(status: 200, headers: headers, body: data(timingStatsJSON(stats)))
        default:
            return nil
        }
    }

    /// A `TimingEdit` body as the edit.
    static func edit(_ raw: Any?) -> TimingDraft.Edit? {
        guard let t = raw as? [String: Any], let started = (t["started_at"] as? String).flatMap(RunInstant.parse),
            let segments = t["segments"] as? [[String: Any]]
        else { return nil }
        var out: [TimingDraft.Edit.Segment] = []
        for s in segments {
            guard let end = (s["ended_at"] as? String).flatMap(RunInstant.parse) else { return nil }
            let step = s["step"] as? String
            out.append(.init(kind: step == nil ? .lap : .step, step: step, endedAt: end))
        }
        let pauses = (t["pauses"] as? [[String: Any]] ?? []).compactMap { p -> RunPause? in
            guard let a = (p["start"] as? String).flatMap(RunInstant.parse),
                let b = (p["end"] as? String).flatMap(RunInstant.parse)
            else { return nil }
            return RunPause(start: a, end: b)
        }
        return TimingDraft.Edit(
            startedAt: started, segments: out, skipped: t["skipped"] as? [String] ?? [], pauses: pauses)
    }

    static func timingStatsJSON(_ s: TimingStats.TopicTiming) -> [String: Any] {
        func value(_ n: Int?) -> Any { n ?? NSNull() }
        return [
            "runs": s.runs, "complete_runs": s.completeRuns,
            "total": [
                "best_ms": value(s.total.bestMs), "median_ms": value(s.total.medianMs),
                "mean_ms": value(s.total.meanMs),
            ],
            "steps": s.steps.map { step -> [String: Any] in
                [
                    "key": step.key, "label": step.label, "current": step.current, "done": step.done,
                    "skipped": step.skipped, "best_ms": value(step.bestMs), "median_ms": value(step.medianMs),
                    "mean_ms": value(step.meanMs),
                ]
            },
            "laps": [
                "runs_with_laps": s.laps.runsWithLaps, "median_ms": value(s.laps.medianMs),
                "mean_ms": value(s.laps.meanMs),
            ],
            "paused": ["runs_with_pauses": s.paused.runsWithPauses, "median_ms": value(s.paused.medianMs)],
            "series": s.series.map { p -> [String: Any] in
                [
                    "entry_id": p.entryId, "captured_at": RunInstant.format(p.capturedAt),
                    "started_at": RunInstant.format(p.startedAt), "active_ms": p.activeMs, "paused_ms": p.pausedMs,
                    "complete": p.complete, "steps": p.steps,
                ]
            },
        ]
    }
}
#endif
