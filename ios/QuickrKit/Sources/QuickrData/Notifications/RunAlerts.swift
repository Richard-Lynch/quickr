import Foundation
import QuickrCore

/// Run alerts (timers2.md §9.1): the lap/step alerts of an open run, delivered as local
/// notifications. The planner (`RunAlertPlan`) is here, the scheduler in `RunAlertScheduler`;
/// both read the one constant below, so the OQ-6 fallback is a single-line change.
public enum RunAlerts {
    /// timers2.md §9.1 / OQ-6 rider: `.timeSensitive` needs the entitlement in `ios/project.yml`
    /// (T2-M1 block) and the capability on the App ID; flip to `.active` if `v0.4.0-rc1` fails to sign.
    public static let interruptionLevel: NotificationInterruptionLevel = .timeSensitive

    /// The `quickr.kind` of a run alert.
    public static let kind = "alert"
    /// Every run alert's identifier starts with this.
    public static let identifierPrefix = "quickr.alert."

    /// The prefix of one run's alerts: `quickr.alert.{run_id}.`
    public static func identifierPrefix(runId: String) -> String { "\(identifierPrefix)\(runId.lowercased())." }
}

/// The pure planner (timers2.md §9.1): what a run's pending alerts should be now.
public enum RunAlertPlan {
    /// At most this many pending per run (iOS keeps 64 pending requests per app).
    public static let maxPerRun = 8

    /// For the **open segment** only: the alerts of its step or lap type whose instant
    /// `seg_started_at + paused_overlap_so_far + at_ms` is after `now`, earliest first (then in
    /// their order), at most `maxPerRun`. None while paused or once the run isn't open, and none
    /// for an alert the server hasn't evaluated (`at_ms` nil).
    ///
    /// - Parameters:
    ///   - now: this device's clock.
    ///   - serverOffsetMs: the store's `server_offset_ms`: run instants are on the server's clock,
    ///     `fireAt` on this device's.
    ///   - topicName: the title.
    ///   - serverId: the run's server, for `quickr.server_id`.
    public static func requests(
        run: LocalRun, timer: TopicTimer, now: Date, serverOffsetMs: Int = 0, topicName: String, serverId: String
    ) -> [LocalNotificationRequest] {
        let state = run.state
        guard run.isOpen, let open = state.open, state.pausedSince == nil else { return [] }
        let nowMs = RunInstant.milliseconds(now) + serverOffsetMs
        // The segment's closed pauses so far; none can start after now, so this is stable.
        let to = max(nowMs, open.startedAt)
        let paused = state.pauses.reduce(0) { sum, pause in
            sum + max(0, min(pause.end, to) - max(pause.start, open.startedAt))
        }
        let runId = run.id.lowercased()
        let topicId = run.topicId.wireString
        return timer.alerts(step: open.step, lapType: open.lapType).enumerated()
            .compactMap { index, alert -> (at: Int, index: Int, alert: TopicTimer.Alert)? in
                guard let atMs = alert.atMs else { return nil }
                let at = open.startedAt + paused + atMs
                return at > nowMs ? (at, index, alert) : nil
            }
            .sorted { ($0.at, $0.index) < ($1.at, $1.index) }
            .prefix(maxPerRun)
            .map { at, _, alert in
                let fireAtMs = at - serverOffsetMs
                return LocalNotificationRequest(
                    id: "\(RunAlerts.identifierPrefix(runId: runId))\(open.index).\(alert.key)",
                    title: topicName, body: "\(alert.label) · \(open.label)", threadIdentifier: "topic-\(topicId)",
                    quickr: QuickrNotificationInfo(
                        kind: RunAlerts.kind, origin: .local, serverId: serverId.lowercased(), topicId: topicId,
                        runId: runId, alertLabel: alert.label, fireAtMs: fireAtMs),
                    sound: true, fireAt: Date(timeIntervalSince1970: TimeInterval(fireAtMs) / 1000),
                    interruptionLevel: RunAlerts.interruptionLevel)
            }
    }
}
