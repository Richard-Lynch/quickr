import QuickrCore

// The one title, SF Symbol and VoiceOver table for a run action (active-surfaces.md §1.3), for
// every surface that renders `RunAction`s: the run screen's controls and the home card. Pure
// strings: placement is `RunControlsLayout`'s, by role; this is the only per-kind rendering.

extension RunAction {
    /// The button's title. `…` marks a confirmation.
    public var title: String {
        switch kind {
        case .start: "Start"
        // `next("Next")` is the steps-unknown fallback (timers2.md §10): a plain "Next".
        case .next(let label): label == "Next" ? label : "Next: \(label)"
        case .lap(let next): next.map { "Lap → \($0)" } ?? "Lap"
        case .skip(let label): "Skip \(label)"
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop"
        case .addDetails: "Add details"
        case .reopen: "Resume run"
        case .revert: "Undo resume…"
        case .discard: "Discard run…"
        }
    }

    /// The SF Symbol beside the title.
    public var systemImage: String {
        switch kind {
        case .start, .resume: "play"
        case .next: "chevron.right"
        case .lap: "flag"
        case .skip: "forward.end"
        case .pause: "pause"
        case .stop: "stop"
        case .addDetails: "pencil"
        case .reopen: "arrow.uturn.backward"
        case .revert: "arrow.uturn.forward"
        case .discard: "trash"
        }
    }

    /// What VoiceOver reads for the control of `topic` (the topic's name).
    public func spokenTitle(topic: String) -> String {
        switch kind {
        case .start: "Start \(topic)"
        case .lap(let next?): "Lap, then \(next)"
        case .stop: "Stop \(topic)"
        case .addDetails: "Add details to \(topic)"
        case .reopen: "Resume the last run of \(topic)"
        case .revert: "Undo the resume and keep the stop"
        case .discard: "Discard run"
        case .next, .lap, .skip, .pause, .resume: title
        }
    }
}
