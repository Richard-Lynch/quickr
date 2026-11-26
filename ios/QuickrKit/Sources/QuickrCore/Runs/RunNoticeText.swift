import Foundation

/// The §11.4 notices' text (timers.md; timers2.md §9.3): what a run tap of this device that the
/// server voided says,
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
        case .reopen: "Resume"
        case .remove: "Remove"
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
        // timers2.md §9.3. Who is told is the ack's decision (`RunVoid`): `reverted` only on the
        // device whose reopen another device's discard undid, `not_stopped` not after a double tap.
        case .reverted: return "\(topic)’s resume was undone by a discard elsewhere."
        case .notStopped: return "\(topic) isn’t stopped, so there was nothing to resume."
        case .noTarget:
            return tap == .remove
                ? "Couldn’t remove that: \(topic)’s run changed." : "Couldn’t resume: \(topic)’s run changed."
        // The removed tap was removed on purpose.
        case .deleted: return nil
        }
    }
}
