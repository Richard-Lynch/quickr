import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

// The run's Live Activity (timers.md §10.3, §10.4): its attributes and content state, as the
// server's pushes carry them (backend/app/services/push/live_activity.py), and the same content
// built here from the local view of a run. Pinned by shared/fixtures/live-activity-vectors.json
// (`LiveActivityVectorTests`).

/// `RunActivityState` (§10.3), the activity's `ContentState`. Part of the push contract: fields are
/// only ever added, as optionals. Instants are Unix seconds as `Double`, never `Date` (ActivityKit
/// decodes a `Date` from 2001).
public struct RunActivityState: Codable, Sendable, Hashable {
    public var v: Int
    /// Lowercase.
    public var runId: String
    public var revision: Int
    /// `running` or `paused`; once ended `finishing`, `stopped` or `discarded`.
    public var status: String
    public var startedAt: Double
    /// The open segment (once closed, the last one; 0 for a run discarded before Next).
    public var seg: Int
    public var segStartedAt: Double
    /// The segment's label (a step's, or "Lap n"), at most 64 characters.
    public var label: String
    /// The open step's 0-based position among the version's steps; nil in a lap.
    public var stepIndex: Int?
    public var stepCount: Int
    /// What Next would start; nil on the last step and without steps.
    public var nextLabel: String?
    public var pausedAt: Double?
    /// Ended pauses before the segment started, and inside it.
    public var pausedMsBeforeSeg: Int
    public var pausedMsInSeg: Int
    /// What was saved, once `finishing` or `stopped`; nil otherwise (discarded included).
    public var endedAt: Double?
    public var activeMs: Int?
    /// This device's own: true when it built the state without the pinned version's steps (not
    /// stored here yet), so a step may remain whatever `next_label` says. Never in a push.
    public var stepsUnknown: Bool?

    enum CodingKeys: String, CodingKey {
        case v, revision, status, seg, label
        case runId = "run_id"
        case startedAt = "started_at"
        case segStartedAt = "seg_started_at"
        case stepIndex = "step_index"
        case stepCount = "step_count"
        case nextLabel = "next_label"
        case pausedAt = "paused_at"
        case pausedMsBeforeSeg = "paused_ms_before_seg"
        case pausedMsInSeg = "paused_ms_in_seg"
        case endedAt = "ended_at"
        case activeMs = "active_ms"
        case stepsUnknown = "steps_unknown"
    }

    public init(
        v: Int = RunActivityContent.version, runId: String, revision: Int, status: String, startedAt: Double,
        seg: Int, segStartedAt: Double, label: String, stepIndex: Int?, stepCount: Int, nextLabel: String?,
        pausedAt: Double?, pausedMsBeforeSeg: Int, pausedMsInSeg: Int, endedAt: Double?, activeMs: Int?,
        stepsUnknown: Bool? = nil
    ) {
        self.v = v
        self.runId = runId
        self.revision = revision
        self.status = status
        self.startedAt = startedAt
        self.seg = seg
        self.segStartedAt = segStartedAt
        self.label = label
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.nextLabel = nextLabel
        self.pausedAt = pausedAt
        self.pausedMsBeforeSeg = pausedMsBeforeSeg
        self.pausedMsInSeg = pausedMsInSeg
        self.endedAt = endedAt
        self.activeMs = activeMs
        self.stepsUnknown = stepsUnknown
    }

    /// The run's status, when it is one this build knows.
    public var runStatus: RunStatus? { RunStatus(rawValue: status) }

    /// What the activity shows: everything but the revision, which only orders the server's
    /// states (a local state built over queued taps keeps the server's last one).
    public func showsSame(as other: RunActivityState) -> Bool {
        var other = other
        other.revision = revision
        return self == other
    }
}

/// `RunActivityAttributes` (§10.3): one activity per (server, topic), so a merge never leaves two.
/// No step list: it could be the wrong version's after a merge, and could push a push-to-start
/// payload over 4 KB. The push's `attributes-type` is this type's name.
public struct RunActivityAttributes: Codable, Sendable, Hashable {
    public typealias ContentState = RunActivityState

    public var serverId: String
    /// Lowercase.
    public var topicId: String
    /// At most 64 characters.
    public var topicName: String

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case topicId = "topic_id"
        case topicName = "topic_name"
    }

    public init(serverId: String, topicId: String, topicName: String) {
        self.serverId = serverId
        self.topicId = topicId
        self.topicName = topicName
    }
}

#if canImport(ActivityKit) && os(iOS)
extension RunActivityAttributes: ActivityAttributes {}
#endif

/// The content state and attributes from a run: `content_state` and `attributes` of
/// live_activity.py, over the fold's state (`RunState`) and the pinned version's steps.
public enum RunActivityContent {
    public static let version = 1
    /// The topic name and step labels in an activity (§10.3).
    public static let maxLabelLength = 64
    /// Each local update marks the activity stale this far ahead, as the server's pushes do: an
    /// orphaned activity shows as stale instead of ticking silently to iOS's 8-hour limit.
    public static let staleSeconds: TimeInterval = 4 * 3600
    /// An ended activity stays this long ("Saved · 7:42", "Add details").
    public static let dismissSeconds: TimeInterval = 15 * 60

    /// At most `limit` characters (Unicode scalars), the "…" included: the server's `truncate`.
    public static func truncate(_ text: String, _ limit: Int = maxLabelLength) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        var view = String.UnicodeScalarView(scalars.prefix(limit - 1))
        view.append("…")
        return String(view)
    }

    /// The server id lowercase, like every id here.
    public static func attributes(serverId: String, topicId: UUID, topicName: String) -> RunActivityAttributes {
        RunActivityAttributes(
            serverId: serverId.lowercased(), topicId: topicId.uuidString.lowercased(), topicName: truncate(topicName))
    }

    /// `status` is the run's own (the server's `finishing` included), not the fold's.
    ///
    /// While the run is open the segment fields describe the open segment; once closed, its last
    /// one (segment 0 from the start when it has none). `ended_at` and `active_ms` say what was
    /// saved, so only `finishing` and `stopped` carry them. The paused fields count ended pauses
    /// only, split at the segment's start; an open pause is `paused_at`.
    public static func state(
        runId: String, revision: Int, status: RunStatus, state: RunState, steps: [TopicTimer.Step]
    ) -> RunActivityState {
        let keys = steps.map(\.key)
        let seg: Int
        let kind: RunSegmentKind
        let step: String?
        let label: String
        let segStartedAt: Int
        if let open = state.open {
            (seg, kind, step, label, segStartedAt) = (open.index, open.kind, open.step, open.label, open.startedAt)
        } else if let last = state.segments.last {
            (seg, kind, step, label, segStartedAt) = (
                state.segments.count - 1, last.kind, last.step, last.label, last.startedAt
            )
        } else {
            (seg, kind, step, label, segStartedAt) = (0, .lap, nil, "", state.startedAt)
        }
        var nextLabel: String?
        if state.open != nil, let next = state.nextStep, let index = keys.firstIndex(of: next) {
            nextLabel = truncate(steps[index].label)
        }
        let closed = status == .finishing || status == .stopped
        let endedAt = closed ? state.endedAt : nil
        var before = 0
        var inside = 0
        for pause in state.pauses {
            before += max(0, min(pause.end, segStartedAt) - pause.start)
            inside += max(0, pause.end - max(pause.start, segStartedAt))
        }
        let stepIndex: Int? = kind == .step ? step.flatMap { keys.firstIndex(of: $0) } : nil
        let activeMs: Int? = endedAt == nil ? nil : state.segments.reduce(0) { $0 + $1.activeMs }
        return RunActivityState(
            runId: runId.lowercased(), revision: revision, status: status.rawValue,
            startedAt: seconds(state.startedAt), seg: seg, segStartedAt: seconds(segStartedAt),
            label: truncate(label), stepIndex: stepIndex, stepCount: steps.count, nextLabel: nextLabel,
            pausedAt: state.pausedSince.map(seconds), pausedMsBeforeSeg: before, pausedMsInSeg: inside,
            endedAt: endedAt.map(seconds), activeMs: activeMs)
    }

    /// Epoch milliseconds as Unix seconds.
    public static func seconds(_ ms: Int) -> Double { Double(ms) / 1000 }
}
