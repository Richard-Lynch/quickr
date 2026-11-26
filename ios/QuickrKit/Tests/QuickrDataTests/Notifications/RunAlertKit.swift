import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// Runs for the run-alert suites (timers2.md §9.1, R17): a laps-only timer whose second lap type,
/// a 60 s rest, alerts at `t/2` and `t`, folded from events at epoch milliseconds after `t0`.
enum RunAlertKit {
    static let runId = "0a000000-0000-4000-8000-0000000000aa"
    static let topicId = UUID(uuidString: "6f1c0000-0000-4000-8000-000000000002")!
    static let serverId = "0b9e0000-0000-4000-8000-000000000001"
    /// The run's start, server clock.
    static let t0 = 1_800_000_000_000

    static func alert(_ key: String, _ label: String, _ at: String, _ ms: Int?) -> TopicTimer.Alert {
        TopicTimer.Alert(key: key, label: label, at: at, atMs: ms)
    }

    /// Run, then Rest (60 s: "Half way" at `t/2`, "Go" at `t`).
    static let timer = TopicTimer(
        steps: [],
        laps: [
            TopicTimer.LapType(key: "run", label: "Run"),
            TopicTimer.LapType(
                key: "rest", label: "Rest",
                alerts: [alert("half", "Half way", "t/2", 30_000), alert("go", "Go", "t", 60_000)]),
        ],
        variables: [TopicTimer.Variable(name: "t", ms: 60_000)])

    /// `seconds` after the start, server clock.
    static func at(_ seconds: Double) -> Int { t0 + Int(seconds * 1000) }

    /// This device's `Date` for a server instant, at `offsetMs`.
    static func date(_ ms: Int, offsetMs: Int = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms - offsetMs) / 1000)
    }

    static func lap(_ id: String, _ seconds: Double, seg: Int) -> RunEvent {
        RunEvent(id: id, type: .lap, at: at(seconds), seg: seg)
    }

    static func pause(_ id: String, _ seconds: Double) -> RunEvent { RunEvent(id: id, type: .pause, at: at(seconds)) }

    static func resume(_ id: String, _ seconds: Double, pause: String) -> RunEvent {
        RunEvent(id: id, type: .resume, at: at(seconds), pauseId: pause)
    }

    static func stop(_ seconds: Double) -> RunEvent {
        RunEvent(id: "0e000000-0000-4000-8000-0000000000ff", type: .stop, at: at(seconds))
    }

    static func discard(_ seconds: Double) -> RunEvent {
        RunEvent(id: "0e000000-0000-4000-8000-0000000000fd", type: .discard, at: at(seconds))
    }

    /// The run after `events` (its start first), as the local view would have it.
    static func run(_ events: [RunEvent], id: String = runId, timer: TopicTimer = timer) throws -> LocalRun {
        let all = [RunEvent(id: id, type: .start, at: t0)] + events
        let state = try RunFold.fold(runId: id, timer: timer, events: all)
        return LocalRun(
            id: id, topicId: topicId, topic: nil, version: 1, status: state.status, state: state, events: all,
            aliases: [], server: nil, queued: [], steps: timer.steps, requiresAnswers: false, hasQuestions: false,
            timer: timer)
    }

    /// Resting since 10 s: the first lap closed at 10 s.
    static func resting(_ more: [RunEvent] = []) throws -> LocalRun { try run([lap("l1", 10, seg: 0)] + more) }

    static func plan(_ run: LocalRun, now seconds: Double, offsetMs: Int = 0, timer: TopicTimer = timer)
        -> [LocalNotificationRequest]
    {
        RunAlertPlan.requests(
            run: run, timer: timer, now: date(at(seconds), offsetMs: offsetMs), serverOffsetMs: offsetMs,
            topicName: "Intervals", serverId: serverId)
    }
}
