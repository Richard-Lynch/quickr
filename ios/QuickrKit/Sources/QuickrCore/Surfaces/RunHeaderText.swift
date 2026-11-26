import Foundation

/// The run screen's and the active card's words that aren't a button's (active-surfaces.md §2.1,
/// §2.4, §3.2, §3.3): the state badge, the alert line's choice, the typed lap rows' badges, and an
/// idle Resume's title. Pure; the views only render them. Button titles are `RunActionLabel`'s
/// (§1.3).
public enum RunHeaderText {
    /// The state badge (`run.state`): "Resuming…" while a reopen from the entry waits for its ack
    /// (timers2.md §5.3, §1.2 row 11), else "Paused" or "Running".
    public static func state(resuming: Bool, paused: Bool) -> String {
        resuming ? "Resuming…" : paused ? "Paused" : "Running"
    }

    /// The alert line (`run.alert`): a fired alert's label for its 10 s (timers2.md §9, I1-ALERTS'
    /// `runAlerts.label(runId:)`), else the next alert's countdown (`RunPresentation.alertLine`).
    public struct AlertLine: Sendable, Hashable {
        public var text: String
        /// The label of an alert that just fired (shown with a bell), not a countdown.
        public var fired: Bool
    }

    public static func alert(fired: String?, next: String?) -> AlertLine? {
        if let fired, !fired.isEmpty { return AlertLine(text: fired, fired: true) }
        return next.map { AlertLine(text: $0, fired: false) }
    }

    /// The lap-type badge of each typed lap row (§2.1), by `RunPresentation.Row.id` ("lap.{n}",
    /// the closed laps then the open one): the type's label from the pinned timer, the key when
    /// the timer no longer has it. Untyped laps have none; nothing when the timer isn't known.
    public static func lapTypeBadges(_ state: RunState, timer: TopicTimer?) -> [String: String] {
        guard let timer else { return [:] }
        let types =
            state.segments.filter { $0.kind == .lap }.map(\.lapType)
            + (state.open.map { $0.kind == .lap ? [$0.lapType] : [] } ?? [])
        var out: [String: String] = [:]
        for (index, type) in types.enumerated() {
            guard let type else { continue }
            out["lap.\(index + 1)"] = timer.laps.first { $0.key == type }?.label ?? type
        }
        return out
    }

    /// An idle Resume's title with the stopped run's total: "Resume · 1:44" (§1.3, §2.4, §3.3).
    public static func reopenTitle(totalMs: Int) -> String { "Resume · \(DurationFormat.format(totalMs))" }
}
