#if DEBUG
import Foundation
import QuickrCore
import QuickrData
import Synchronization

/// `-QuickrSeedTimedTopic` (I-MANAGE's UI tests, timers.md §3.8, §9): the fake server's timed
/// topic, Morning (`FakeServer.morningId`), has one finished, complete run logged yesterday:
/// Shower 4:00, Dress 5:00, Breakfast 1:00, then Teeth 3:00. It answers Edit times (`PATCH /entries/{id}` with
/// `timing`, rebuilt as the backend's `edited_timing` does, checked against `expected_revision`),
/// `GET /entries/{id}`, and the topic's stats and timing stats (`TimingStats`, the backend's port).
enum FakeTiming {
    static let flag = "-QuickrSeedTimedTopic"
    static var morningId: UUID { FakeServer.morningId }
    static let entryId = UUID(uuidString: "00000000-0000-4000-8000-0000000000e3")!
    /// `FakeServer.morningTimer`'s steps.
    static let steps: [TopicTimer.Step] = {
        guard let timer = try? JSONDecoder().decode(TopicTimer.self, from: Data(FakeServer.morningTimer.utf8)) else {
            return []
        }
        return timer.steps
    }()

    static var isEnabled: Bool {
        UITestLaunch.isActive && ProcessInfo.processInfo.arguments.contains(flag)
    }

    private struct State {
        var revision = 1
        var timing: Timing
    }

    private static let state = Mutex(State(timing: seededTiming()))

    /// Yesterday 07:00 (UTC): Shower to 07:04, Dress to 07:09, Breakfast to 07:10, Teeth to 07:13.
    static func seededTiming(now: Date = Date()) -> Timing {
        let day = RunInstant.milliseconds(now) / 86_400_000 - 1  // after 1970: truncation is floor
        let start = day * 86_400_000 + 7 * 3_600_000
        let ends = [4, 9, 10, 13].map { start + $0 * 60_000 }
        return TimingDraft.Edit(
            startedAt: start,
            segments: zip(steps, ends).map { .init(kind: .step, step: $0.key, endedAt: $1) },
            skipped: [], pauses: []
        ).timing(steps: steps)
    }

    /// The feed items the server starts with: the run's entry (Morning and its version are
    /// `FakeServer`'s seeded page).
    static func seedFeed() -> [String] {
        guard isEnabled else { return [] }
        let entry: [String: Any] = ["kind": "entry", "seq": FakeServer.seededHead + 1, "entry": entryJSON()]
        return [entry].compactMap(json)
    }

    /// The run's entry as `EntryOut`.
    static func entryJSON() -> [String: Any] {
        let (revision, timing) = state.withLock { ($0.revision, $0.timing) }
        let end = RunInstant.format(timing.endedAt)
        return [
            "id": entryId.wireString, "topic_id": morningId.wireString, "version": 1, "revision": revision,
            "source": "ios", "channel": "ios", "captured_at": end, "created_at": end, "updated_at": end, "notes": "",
            "meta": [String: String](), "answers": [["key": "mood", "type": "enum", "value": "good"]],
            "timing": timingJSON(timing),
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
            else {
                return problem(
                    422, "invalid_request", "invalid timing: a step segment names its step, a lap names none",
                    loc: ["body", "timing"])
            }
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
            guard let end = (s["ended_at"] as? String).flatMap(RunInstant.parse),
                let kind = (s["kind"] as? String).flatMap(RunSegmentKind.init(rawValue:))
            else { return nil }
            let step = s["step"] as? String
            // The backend's rule: a step segment names its step, a lap names none.
            guard (kind == .step) == (step != nil) else { return nil }
            out.append(.init(kind: kind, step: step, endedAt: end))
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
