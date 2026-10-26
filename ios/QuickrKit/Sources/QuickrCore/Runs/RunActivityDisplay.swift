import Foundation

/// What the Live Activity shows (timers.md §10.3, Presentation), from its content state alone: the
/// Lock Screen, the banner and the Dynamic Island read the same strings, timers and buttons.
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

    /// A Live Activity button: each one is a `run.event` tap.
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

    public var phase: Phase
    public var topicName: String
    /// The segment's label: a step's, or "Lap n".
    public var label: String
    /// "2 of 5" in a step; nil in a lap and without steps.
    public var position: String?
    /// The compact Dynamic Island's leading text: the 1-based step number, or nil for the timer
    /// glyph.
    public var stepNumber: String?
    /// What Next starts ("Next: Breakfast" for VoiceOver); nil when Next isn't offered.
    public var nextLabel: String?
    /// While running or paused: the open segment's active time, and the run's.
    public var segmentTimer: Timer?
    public var totalTimer: Timer?
    /// Once ended: "Saved · 7:42", "Add details" or "Discarded".
    public var endedText: String?
    /// The Lock Screen's buttons, in order: Next (or Lap without steps and on the last step),
    /// Pause or Resume, Stop; a plain Next when the steps aren't known. None once ended.
    public var buttons: [Button]

    /// The expanded Dynamic Island's: Next (or Lap) and Stop.
    public var islandButtons: [Button] { buttons.filter { $0 != .pause && $0 != .resume } }

    public init(state: RunActivityState, topicName: String) {
        self.topicName = topicName
        label = state.label
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
            // Steps not known here: a plain Next (a step may remain), never Lap.
            let primary: Button = state.nextLabel != nil || state.stepsUnknown == true ? .next : .lap
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
