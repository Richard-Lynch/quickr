import Foundation

/// What the Live Activity shows (timers.md §10.3, Presentation; active-surfaces.md §4), from its
/// content state alone: the Lock Screen, the banner and the Dynamic Island read the same strings,
/// timers and buttons.
///
/// Pure. The timers are rendered by the system (`Text(timerInterval:pauseTime:)`), so they tick
/// without updates: each is a start shifted later by the paused time it excludes, frozen at the
/// open pause.
public struct RunActivityDisplay: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case running, paused
        /// Stopped, waiting for its answers.
        case finishing
        case saved
        case discarded
    }

    /// A Live Activity button: each one is a `run.event` tap. `title` is the plain one; the
    /// display's `title(for:)` adds what Next or Lap opens.
    public enum Button: String, Sendable, Hashable, CaseIterable {
        case next, lap, pause, resume, stop

        public var title: String {
            switch self {
            case .next: "Next"
            case .lap: "Lap"
            case .pause: "Pause"
            case .resume: "Resume"
            case .stop: "Stop"
            }
        }

        public var tap: RunEventType {
            switch self {
            case .next: .next
            case .lap: .lap
            case .pause: .pause
            case .resume: .resume
            case .stop: .stop
            }
        }
    }

    /// A ticking timer: `start` (Unix seconds) is when it would read 0:00 had nothing paused it;
    /// `pausedAt` freezes it there.
    public struct Timer: Sendable, Hashable {
        public var start: Double
        public var pausedAt: Double?

        /// What it reads at `now` (Unix seconds), in milliseconds.
        public func ms(at now: Double) -> Int {
            max(0, Int((((pausedAt.map { min($0, now) } ?? now) - start) * 1000).rounded(.down)))
        }
    }

    /// The next alert of the open segment (active-surfaces.md §4.1): its label and when it fires
    /// (Unix seconds), for a `Text(timerInterval:countsDown:)` to it.
    public struct Alert: Sendable, Hashable {
        public var label: String
        public var at: Double

        public init(label: String, at: Double) {
            self.label = label
            self.at = at
        }
    }

    public var phase: Phase
    public var topicName: String
    /// The segment's label: a step's, or "Lap n".
    public var label: String
    /// The open segment's label with its counter, as the run screen's (`RunPresentation.headline`):
    /// "Rest 2 · lap 4" in a typed lap, "Lap 3" in an untyped one, "Shower · 2 of 5" in a step;
    /// the bare label once ended, and without `lap_count` (a v1 state). The Lock Screen's second
    /// line and the expanded Dynamic Island's centre.
    public var headline: String
    /// "2 of 5" in a step; nil in a lap and without steps.
    public var position: String?
    /// The 1-based step number in a step; nil in a lap and without steps.
    public var stepNumber: String?
    /// The compact Dynamic Island's lap counter ("L4": `lap_count + 1`) while a lap is open; nil
    /// in a step, once ended, without `lap_count` (a v1 state) and when the steps aren't known.
    public var lapCounter: String?
    /// The content state's `next_label` while open: the step Next would start. Nil when none is
    /// known. (M1's state also sets it during a lap, to the lap type a Lap opens: that reading is
    /// `lapNextLabel`.)
    public var nextLabel: String?
    /// What a Lap opens when the lap types say ("Rest"), for the §1.3 title "Lap → Rest": the
    /// content state's `next_label` while a typed lap is open (timers2.md §8.1). Nil in a step
    /// and in an untyped lap, where `next_label` can only be the step Next would start, which a
    /// Lap does not open.
    public var lapNextLabel: String?
    /// While running or paused: the open segment's active time, and the run's.
    public var segmentTimer: Timer?
    public var totalTimer: Timer?
    /// The pending alert while running (`alert_at`, `alert_label`): nil while paused, once ended,
    /// and when none is pending. The label is empty when the payload budget dropped it.
    public var alert: Alert?
    /// Once ended: "Saved · 7:42", "Add details" or "Discarded".
    public var endedText: String?
    /// The Lock Screen's buttons, in order: the primary (active-surfaces.md §4.1: Next while a
    /// step is open and another follows, or when the steps aren't known; Lap otherwise), Pause or
    /// Resume, Stop. None once ended.
    public var buttons: [Button]

    /// The primary: `buttons[0]`; nil once ended.
    public var primary: Button? { buttons.first }

    /// The expanded Dynamic Island's: the primary and Stop.
    public var islandButtons: [Button] { buttons.filter { $0 != .pause && $0 != .resume } }

    /// The compact Dynamic Island's leading text: the lap counter during a lap, the step number
    /// in a step; nil for the timer glyph.
    public var compactLeading: String? { lapCounter ?? stepNumber }

    /// A button's title (active-surfaces.md §1.3): "Next: Shower", "Lap → Rest" when
    /// `lapNextLabel` names what the lap opens, else the plain title.
    public func title(for button: Button) -> String {
        switch button {
        case .next: nextLabel.map { "Next: \($0)" } ?? button.title
        case .lap: lapNextLabel.map { "Lap → \($0)" } ?? button.title
        case .pause, .resume, .stop: button.title
        }
    }

    /// The title VoiceOver reads (§1.3): "Lap, then Rest", "Stop Morning routine"; otherwise
    /// `title(for:)`.
    public func spokenTitle(for button: Button) -> String {
        switch button {
        case .lap: lapNextLabel.map { "Lap, then \($0)" } ?? title(for: button)
        case .stop: "Stop \(topicName)"
        case .next, .pause, .resume: title(for: button)
        }
    }

    public init(state: RunActivityState, topicName: String) {
        self.topicName = topicName
        label = state.label
        headline = state.label
        let status = state.runStatus
        switch status {
        case .paused: phase = .paused
        case .finishing: phase = .finishing
        case .stopped: phase = .saved
        case .discarded: phase = .discarded
        case .running, nil: phase = .running
        }
        if let index = state.stepIndex, state.stepCount > 0 {
            position = "\(index + 1) of \(state.stepCount)"
            stepNumber = "\(index + 1)"
        }
        switch phase {
        case .running, .paused:
            let pausedAt = state.pausedAt
            let segmentPausedAt = pausedAt.map { max($0, state.segStartedAt) }
            segmentTimer = Timer(
                start: state.segStartedAt + Double(state.pausedMsInSeg) / 1000, pausedAt: segmentPausedAt)
            totalTimer = Timer(
                start: state.startedAt + Double(state.pausedMsBeforeSeg + state.pausedMsInSeg) / 1000,
                pausedAt: pausedAt)
            nextLabel = state.nextLabel
            // A lap is open when no step is (`step_index` is set in every step of known steps).
            if state.stepIndex == nil, state.stepsUnknown != true, let closed = state.lapCount {
                let n = closed + 1
                lapCounter = "L\(n)"
                if state.lapType != nil {
                    headline = "\(state.label) · lap \(n)"
                    lapNextLabel = state.nextLabel
                }
            } else if let position {
                headline = "\(state.label) · \(position)"
            }
            if phase == .running, let at = state.alertAt {
                alert = Alert(label: state.alertLabel ?? "", at: at)
            }
            // §4.1: Next only when a step is open and another follows, or when the steps aren't
            // known here (a step may remain whatever `next_label` says); else Lap, a lap being
            // open or the last step.
            let primary: Button =
                state.stepsUnknown == true || (state.stepIndex != nil && state.nextLabel != nil) ? .next : .lap
            buttons = [primary, phase == .paused ? .resume : .pause, .stop]
        case .finishing:
            endedText = "Add details"
            buttons = []
        case .saved:
            endedText = state.activeMs.map { "Saved · \(DurationFormat.format($0))" } ?? "Saved"
            buttons = []
        case .discarded:
            endedText = "Discarded"
            buttons = []
        }
    }
}
