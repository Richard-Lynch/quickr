#if DEBUG
import Foundation
import QuickrCore
import QuickrData

/// `-QuickrSeedTypedTopic` (M4's UI tests and screenshots, content-display.md §3, §4): the fake
/// server gains Intervals (`topicId`), timed with timers2.md §3.1's `tiktok` timer (no steps; lap
/// types Run and Rest, so its laps read Run 1, Rest 1, Run 2, …) and one number question, Effort.
/// It has five finished runs over the last four weeks (`runs`), two of them with a pause, served
/// in the feed, by `GET /entries/{id}` and `GET /topics/{ref}`, and counted by the topic's stats
/// and series (`FakeStats`) and its timing stats (`TimingStats`, the backend's port).
///
/// The figures the tests read: the newest run is 5:00 active (Run 3 · Rest 2, a 20 s pause in
/// Rest 1) with Effort 7; over all five, Run has 12 laps (best 1:10, median and mean 1:40) and
/// Rest 8 (best 0:30, median and mean 0:40).
enum FakeLapTypes {
    static let flag = "-QuickrSeedTypedTopic"
    static let topicId = UUID(uuidString: "00000000-0000-4000-8000-0000000000c4")!
    static let versionId = "00000000-0000-4000-8000-0000000000d4"
    static let slug = "intervals"

    static var isEnabled: Bool {
        UITestLaunch.isActive && ProcessInfo.processInfo.arguments.contains(flag)
    }

    static let questions = #"""
        [{"help_text": null, "key": "effort", "label": "Effort", "max": 10, "min": 1, "required": true,
          "type": "int", "unit": null}]
        """#
    static let timer = #"""
        {"steps": [], "laps": [{"key": "run", "label": "Run", "alerts": []},
                               {"key": "rest", "label": "Rest", "alerts": []}],
         "variables": []}
        """#
    static let lapTypes: [TopicTimer.LapType] = [.init(key: "run", label: "Run"), .init(key: "rest", label: "Rest")]

    /// A finished run: logged `daysAgo` days before today's local midnight plus `hour` (as
    /// `FakeStats` places its entries), its laps' active seconds in order (alternating Run and
    /// Rest), and at most one pause, `at` seconds into lap `lap`, `length` seconds long.
    struct Run: Sendable {
        var id: UUID
        var daysAgo: Int
        var hour: Int
        var laps: [Int]
        var pause: (lap: Int, at: Int, length: Int)?
        var effort: Int
    }

    /// Newest first.
    static let runs: [Run] = [
        Run(id: entryId(1), daysAgo: 1, hour: 7, laps: [90, 30, 80, 30, 70], pause: (1, 10, 20), effort: 7),
        Run(id: entryId(2), daysAgo: 3, hour: 18, laps: [100, 30, 90, 40, 80], effort: 6),
        Run(id: entryId(3), daysAgo: 8, hour: 7, laps: [110, 40, 100], pause: (0, 30, 15), effort: 5),
        Run(id: entryId(4), daysAgo: 15, hour: 7, laps: [120, 45, 110, 45], effort: 4),
        Run(id: entryId(5), daysAgo: 22, hour: 19, laps: [130, 60, 120], effort: 3),
    ]

    static func entryId(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000000f%d", n))!
    }

    /// The runs as `FakeStats` entries, for the topic's stats and Effort's series.
    static var statsEntries: [FakeStats.Entry] {
        runs.map { FakeStats.Entry(daysAgo: $0.daysAgo, hour: $0.hour, source: "ios", numbers: ["effort": $0.effort]) }
    }

    /// When the run ended (its entry's `captured_at`): `FakeStats.filtered`'s instant.
    static func capturedAt(_ run: Run, now: Date = Date()) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.date(byAdding: .day, value: -run.daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return RunInstant.milliseconds(calendar.date(byAdding: .hour, value: run.hour, to: day) ?? day)
    }

    /// The run's timing as fold v4 stores it: typed laps labelled per type (timers2.md §3.2), each
    /// opened by its `lap` event (the first by the start), the pause with its event's id, and the
    /// stop as `terminal_id`.
    static func timing(_ run: Run, now: Date = Date()) -> Timing {
        let active = run.laps.reduce(0, +) * 1000
        let paused = (run.pause?.length ?? 0) * 1000
        let start = capturedAt(run, now: now) - active - paused
        var at = start
        var segments: [RunSegment] = []
        var pauses: [RunPause] = []
        for (i, seconds) in run.laps.enumerated() {
            let type = lapTypes[i % lapTypes.count]
            var inLap = 0
            if let pause = run.pause, pause.lap == i {
                let begin = at + pause.at * 1000
                pauses.append(RunPause(start: begin, end: begin + pause.length * 1000, id: eventId(run, 90)))
                inLap = pause.length * 1000
            }
            let end = at + seconds * 1000 + inLap
            segments.append(
                RunSegment(
                    kind: .lap, step: nil, label: "\(type.label) \(i / lapTypes.count + 1)", startedAt: at,
                    endedAt: end, activeMs: seconds * 1000, pausedMs: inLap, lapType: type.key,
                    eventId: i == 0 ? nil : eventId(run, i), openedBy: i == 0 ? .start : .lap))
            at = end
        }
        return Timing(
            startedAt: start, endedAt: at, activeMs: active, pausedMs: paused, complete: true, edited: false,
            segments: segments, skipped: [], pauses: pauses, terminalId: eventId(run, 99))
    }

    /// A stable event id per run and slot (a lap's index, 90 the pause, 99 the stop).
    private static func eventId(_ run: Run, _ slot: Int) -> String {
        let n = runs.firstIndex { $0.id == run.id } ?? 0
        return String(format: "00000000-0000-4000-8%03d-%012d", n + 1, slot)
    }

    // MARK: - Feed

    /// The topic's version and topic rows, then its runs' entries, oldest first, from `firstSeq`.
    static func seedFeed(firstSeq: Int) -> [String] {
        guard isEnabled else { return [] }
        var items = [
            FakeServer.version(topicId, versionId: versionId, questions: questions, seq: firstSeq, timer: timer),
            FakeServer.topic(
                topicId, slug: slug, name: "Intervals", questions: questions, count: 1, seq: firstSeq + 1, timer: timer),
        ]
        for run in runs.reversed() {
            let item: [String: Any] = ["kind": "entry", "seq": firstSeq + items.count, "entry": entryJSON(run)]
            if let data = try? JSONSerialization.data(withJSONObject: item) {
                items.append(String(decoding: data, as: UTF8.self))
            }
        }
        return items
    }

    /// The run's entry as `EntryOut`.
    static func entryJSON(_ run: Run) -> [String: Any] {
        let timing = timing(run)
        let end = RunInstant.format(timing.endedAt)
        return [
            "id": run.id.wireString, "topic_id": topicId.wireString, "version": 1, "revision": 1, "source": "ios",
            "channel": "ios", "captured_at": end, "created_at": end, "updated_at": end, "notes": "",
            "meta": [String: String](), "answers": [["key": "effort", "type": "int", "value": run.effort]],
            "timing": timingJSON(timing),
        ]
    }

    /// `Timing` with its v2 fields (timers2.md §3.3).
    static func timingJSON(_ t: Timing) -> [String: Any] {
        [
            "started_at": RunInstant.format(t.startedAt), "ended_at": RunInstant.format(t.endedAt),
            "active_ms": t.activeMs, "paused_ms": t.pausedMs, "complete": t.complete, "edited": t.edited,
            "terminal_id": t.terminalId ?? NSNull(),
            "segments": t.segments.map { s -> [String: Any] in
                [
                    "kind": s.kind.rawValue, "step": s.step ?? NSNull(), "label": s.label,
                    "started_at": RunInstant.format(s.startedAt), "ended_at": RunInstant.format(s.endedAt),
                    "active_ms": s.activeMs, "paused_ms": s.pausedMs, "lap_type": s.lapType ?? NSNull(),
                    "event_id": s.eventId ?? NSNull(), "opened_by": s.openedBy?.rawValue ?? NSNull(),
                ]
            },
            "skipped": t.skipped,
            "pauses": t.pauses.map { p -> [String: Any] in
                ["start": RunInstant.format(p.start), "end": RunInstant.format(p.end), "id": p.id ?? NSNull()]
            },
        ]
    }

    // MARK: - Routes

    /// `GET /entries/{id}` for a run's entry, `GET /topics/{ref}` and `GET /topics/{ref}/timing`
    /// (filtered by `captured_from`, as the backend's); nil for any other request. The stats and
    /// series are `FakeStats`'s.
    static func route(_ request: HTTPRequest, headers: HTTPHeaders) -> HTTPResponse? {
        guard isEnabled, request.method == .get else { return nil }
        let parts = request.url.path().split(separator: "/").map(String.init)  // api v1 entries|topics …
        func ok(_ object: Any) -> HTTPResponse {
            HTTPResponse(
                status: 200, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        if parts.count == 4, parts[2] == "entries", let run = runs.first(where: { $0.id.wireString == parts[3] }) {
            return ok(entryJSON(run))
        }
        guard parts.count >= 4, parts[2] == "topics", parts[3] == slug || parts[3] == topicId.wireString else {
            return nil
        }
        if parts.count == 4 {
            let item = FakeServer.topic(
                topicId, slug: slug, name: "Intervals", questions: questions, count: 1, seq: 0, timer: timer)
            guard let object = try? JSONSerialization.jsonObject(with: Data(item.utf8)) as? [String: Any],
                let topic = object["topic"]
            else { return nil }
            return ok(topic)
        }
        guard parts.count == 5, parts[4] == "timing" else { return nil }
        let from =
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "captured_from" }?.value.flatMap(WireDate.parse).map(RunInstant.milliseconds)
        let entries = runs.map { run in
            let timing = timing(run)
            return TimingStats.TimedEntry(entryId: run.id.wireString, capturedAt: timing.endedAt, timing: timing)
        }
        .filter { entry in from.map { entry.capturedAt >= $0 } ?? true }
        let stats = TimingStats.compute(
            entries, versions: [1: TopicTimer(steps: [], laps: lapTypes)], currentVersion: 1)
        return ok(FakeTiming.timingStatsJSON(stats))
    }
}
#endif
