import Foundation

// Runs of timed topics (docs/specs/timers.md §2.2, §2.3, §4). Every instant is an integer count of
// epoch milliseconds (`RunInstant`), never a `Date`, so durations are exact integer differences.

/// A run event's type (§3.2).
public enum RunEventType: String, Sendable, Hashable, CaseIterable {
    case start, next, lap, skip, pause, resume, stop, finish, discard
}

/// Why an event had no effect (§4.2).
public enum VoidReason: String, Sendable, Hashable, CaseIterable {
    case merged
    case alreadyClosed = "already_closed"
    case runEdited = "run_edited"
    case entryDeleted = "entry_deleted"
    case beforeStart = "before_start"
    case afterStop = "after_stop"
    case tooLong = "too_long"
    case stale
    case noStep = "no_step"
    case alreadyPaused = "already_paused"
    case notPaused = "not_paused"
}

/// A run's status. The fold says `stopped`; the server says `finishing` while required answers
/// are missing (§3.5).
public enum RunStatus: String, Sendable, Hashable, CaseIterable {
    case running, paused, finishing, stopped, discarded

    /// Running or paused: the topic's one open run (§4.5).
    public var isOpen: Bool { self == .running || self == .paused }
}

public enum RunSegmentKind: String, Sendable, Hashable {
    case step, lap
}

/// One event's effect: applied, or void with its reason.
public enum RunEffect: Sendable, Hashable {
    case applied
    case void(VoidReason)

    public init(_ reason: VoidReason?) { self = reason.map { .void($0) } ?? .applied }

    public var reason: VoidReason? {
        if case .void(let reason) = self { return reason }
        return nil
    }
}

/// One tap. `seg` is set for next, lap and skip, `step` for skip, `pauseId` for resume (§3.2).
/// Ids are compared lowercase.
public struct RunEvent: Sendable, Hashable {
    public var id: String
    public var type: RunEventType
    public var at: Int
    public var seg: Int?
    public var step: String?
    public var pauseId: String?

    public init(id: String, type: RunEventType, at: Int, seg: Int? = nil, step: String? = nil, pauseId: String? = nil) {
        self.id = id
        self.type = type
        self.at = at
        self.seg = seg
        self.step = step
        self.pauseId = pauseId
    }
}

/// The server's cut-off (§4.4): events from arrival index `after` on are void with `reason` and
/// not folded.
public struct RunFrozen: Sendable, Hashable {
    public var after: Int
    public var reason: VoidReason

    public init(after: Int, reason: VoidReason) {
        self.after = after
        self.reason = reason
    }
}

public struct RunPause: Sendable, Hashable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// A closed segment (§2.3).
public struct RunSegment: Sendable, Hashable {
    public var kind: RunSegmentKind
    /// The step's key; nil for a lap.
    public var step: String?
    /// The step's label in the run's version, or "Lap n".
    public var label: String
    public var startedAt: Int
    public var endedAt: Int
    public var activeMs: Int
    public var pausedMs: Int

    public init(
        kind: RunSegmentKind, step: String?, label: String, startedAt: Int, endedAt: Int, activeMs: Int, pausedMs: Int
    ) {
        self.kind = kind
        self.step = step
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeMs = activeMs
        self.pausedMs = pausedMs
    }
}

public struct RunOpenSegment: Sendable, Hashable {
    public var index: Int
    public var kind: RunSegmentKind
    public var step: String?
    public var label: String
    public var startedAt: Int

    public init(index: Int, kind: RunSegmentKind, step: String?, label: String, startedAt: Int) {
        self.index = index
        self.kind = kind
        self.step = step
        self.label = label
        self.startedAt = startedAt
    }
}

/// The fold's output (§4.3), plus the run's start and (when stopped) end. `segments`, `skipped`
/// and `pauses` are the closed ones; an open pause is `pausedSince`.
public struct RunState: Sendable, Hashable {
    public var status: RunStatus
    public var startedAt: Int
    public var endedAt: Int?
    public var open: RunOpenSegment?
    /// The head of the pending steps while the run is open.
    public var nextStep: String?
    public var pausedSince: Int?
    public var segments: [RunSegment]
    public var skipped: [String]
    public var pauses: [RunPause]
    /// By lowercase event id; `finish` events are left out (the server decides them).
    public var effects: [String: RunEffect]

    public init(
        status: RunStatus, startedAt: Int, endedAt: Int?, open: RunOpenSegment?, nextStep: String?,
        pausedSince: Int?, segments: [RunSegment], skipped: [String], pauses: [RunPause],
        effects: [String: RunEffect]
    ) {
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.open = open
        self.nextStep = nextStep
        self.pausedSince = pausedSince
        self.segments = segments
        self.skipped = skipped
        self.pauses = pauses
        self.effects = effects
    }
}

/// `entries.timing` (§2.3): a finished run's times.
public struct Timing: Sendable, Hashable {
    public var startedAt: Int
    /// Equals the entry's `captured_at` (T1).
    public var endedAt: Int
    public var activeMs: Int
    public var pausedMs: Int
    /// No steps, or every step has a segment and none was skipped (§9.1).
    public var complete: Bool
    public var edited: Bool
    public var segments: [RunSegment]
    public var skipped: [String]
    public var pauses: [RunPause]

    public init(
        startedAt: Int, endedAt: Int, activeMs: Int, pausedMs: Int, complete: Bool, edited: Bool,
        segments: [RunSegment], skipped: [String], pauses: [RunPause]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeMs = activeMs
        self.pausedMs = pausedMs
        self.complete = complete
        self.edited = edited
        self.segments = segments
        self.skipped = skipped
        self.pauses = pauses
    }
}

/// A run as the server holds it (`RunOut`): getRun, listRuns, and the `run` of a recorded event.
public struct Run: Sendable, Hashable, Identifiable {
    /// A stored event, in arrival order, with the effect the server recorded.
    public struct StoredEvent: Sendable, Hashable {
        public var event: RunEvent
        public var arrival: Int
        public var effect: RunEffect
        public var source: String

        public init(event: RunEvent, arrival: Int, effect: RunEffect, source: String) {
            self.event = event
            self.arrival = arrival
            self.effect = effect
            self.source = source
        }
    }

    public var id: UUID
    public var topicId: UUID
    /// The topic version whose steps the run follows.
    public var version: Int
    public var status: RunStatus
    public var revision: Int
    public var startedAt: Int
    public var endedAt: Int?
    public var edited: Bool
    public var events: [StoredEvent]
    public var state: RunState
    /// Ids merged into this run (§4.5).
    public var aliases: [UUID]

    public init(
        id: UUID, topicId: UUID, version: Int, status: RunStatus, revision: Int, startedAt: Int, endedAt: Int?,
        edited: Bool, events: [StoredEvent], state: RunState, aliases: [UUID]
    ) {
        self.id = id
        self.topicId = topicId
        self.version = version
        self.status = status
        self.revision = revision
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.edited = edited
        self.events = events
        self.state = state
        self.aliases = aliases
    }

    /// The events in arrival order, as the fold takes them (§4.1), whatever order they're held in.
    public var foldEvents: [RunEvent] { events.sorted { $0.arrival < $1.arrival }.map(\.event) }
}

/// The response of recordRunEvent: the event's effect, the run, and the entry once it is stopped.
public struct RunEventResult: Sendable, Hashable {
    public var eventId: String
    public var effect: RunEffect
    public var run: Run
    public var entry: Entry?

    public init(eventId: String, effect: RunEffect, run: Run, entry: Entry?) {
        self.eventId = eventId
        self.effect = effect
        self.run = run
        self.entry = entry
    }
}
