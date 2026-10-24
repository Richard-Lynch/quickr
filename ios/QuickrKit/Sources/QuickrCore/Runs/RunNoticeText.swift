import Foundation

/// The §11.4 notices' text (timers.md): what a run tap of this device that the server voided says,
/// the PWA's `noticeFor` (`frontend/src/lib/runs/notices.ts`). Nil for the silent reasons, the
/// double taps that did what the user wanted (`stale`, `merged`, `already_paused`, `not_paused`)
/// and the rest.
public enum RunNoticeText {
    /// The tap as the notice names it: "your Next", "your details" (a finish).
    public static func tapName(_ tap: RunEventType) -> String {
        switch tap {
        case .start: "Start"
        case .next: "Next"
        case .lap: "Lap"
        case .skip: "Skip"
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop"
        case .finish: "details"
        case .discard: "Discard"
        }
    }

    /// - Parameter stoppedAt: the run's end (epoch ms), for `after_stop`'s "at {time}"; without it
    ///   the time is left out.
    public static func text(
        topic: String, tap: RunEventType, reason: VoidReason, stoppedAt: Int?, locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let name = tapName(tap)
        switch reason {
        case .afterStop:
            guard let stoppedAt else { return "\(topic) was already stopped, so your \(name) wasn’t added." }
            var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
            style.timeZone = timeZone
            let time = RunInstant.date(stoppedAt).formatted(style)
            return "\(topic) was already stopped at \(time), so your \(name) wasn’t added."
        case .runEdited: return "\(topic)’s times were edited, so your \(name) wasn’t added."
        case .entryDeleted: return "\(topic)’s run was deleted."
        case .alreadyClosed: return "\(topic) was already stopped."
        case .merged, .beforeStart, .tooLong, .stale, .noStep, .alreadyPaused, .notPaused: return nil
        }
    }
}
