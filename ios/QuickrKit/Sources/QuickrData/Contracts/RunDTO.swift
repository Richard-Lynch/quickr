import Foundation

// Runs of timed topics (docs/specs/timers.md §3). The decoders only, so every recorded response
// decodes (G1); the domain models and the fold port come with I-CORE, so each DTO is its own
// domain value for now. Instants stay wire strings: the fold parses them to integer epoch
// milliseconds and never goes through `Date` (timers.md §2.3).

/// One segment of a finished run (`TimingSegment`).
public struct TimingSegmentDTO: Codable, Sendable, Hashable {
    public var kind: String
    @RequiredKey public var step: String?
    public var label: String
    public var startedAt: String
    public var endedAt: String
    public var activeMs: Int
    public var pausedMs: Int

    enum CodingKeys: String, CodingKey {
        case kind, step, label
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case activeMs = "active_ms"
        case pausedMs = "paused_ms"
    }
}

/// `TimingPause`.
public struct TimingPauseDTO: Codable, Sendable, Hashable {
    public var start: String
    public var end: String
}

/// `Timing`: `EntryOut.timing`, a finished run's times (timers.md §2.3).
public struct TimingDTO: Codable, Sendable, Hashable {
    public var startedAt: String
    public var endedAt: String
    public var activeMs: Int
    public var pausedMs: Int
    public var complete: Bool
    public var edited: Bool
    public var segments: [TimingSegmentDTO]
    public var skipped: [String]
    public var pauses: [TimingPauseDTO]

    enum CodingKeys: String, CodingKey {
        case complete, edited, segments, skipped, pauses
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case activeMs = "active_ms"
        case pausedMs = "paused_ms"
    }
}

/// `RunEventEffect`, and the `event` of a `RunEventResult` (with its id).
public struct RunEventEffectDTO: Codable, Sendable, Hashable {
    public var effect: String
    @RequiredKey public var reason: String?
}

/// `RunEventOut`: one event of a `RunOut`, in arrival order.
public struct RunEventDTO: Codable, Sendable, Hashable {
    public var id: String
    public var type: String
    public var at: String
    @RequiredKey public var seg: Int?
    @RequiredKey public var step: String?
    @RequiredKey public var pauseId: String?
    public var arrival: Int
    public var effect: String
    @RequiredKey public var reason: String?
    public var source: String

    enum CodingKeys: String, CodingKey {
        case id, type, at, seg, step, arrival, effect, reason, source
        case pauseId = "pause_id"
    }
}

/// `RunOpenSegment`.
public struct RunOpenSegmentDTO: Codable, Sendable, Hashable {
    public var index: Int
    public var kind: String
    @RequiredKey public var step: String?
    public var label: String
    public var startedAt: String

    enum CodingKeys: String, CodingKey {
        case index, kind, step, label
        case startedAt = "started_at"
    }
}

/// `RunState`: the fold's output (timers.md §4.3).
public struct RunStateDTO: Codable, Sendable, Hashable {
    public var status: String
    public var startedAt: String
    @RequiredKey public var endedAt: String?
    @RequiredKey public var open: RunOpenSegmentDTO?
    @RequiredKey public var nextStep: String?
    @RequiredKey public var pausedSince: String?
    public var segments: [TimingSegmentDTO]
    public var skipped: [String]
    public var pauses: [TimingPauseDTO]
    /// By lowercase event id.
    public var effects: [String: RunEventEffectDTO]

    enum CodingKeys: String, CodingKey {
        case status, open, segments, skipped, pauses, effects
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case nextStep = "next_step"
        case pausedSince = "paused_since"
    }
}

/// `RunOut`: getRun, an item of listRuns, and the `run` of a `RunEventResult`.
public struct RunDTO: Codable, Sendable, Hashable, WireResponse {
    public var id: String
    public var topicId: String
    public var version: Int
    public var status: String
    public var revision: Int
    public var startedAt: String
    @RequiredKey public var endedAt: String?
    public var edited: Bool
    public var events: [RunEventDTO]
    public var state: RunStateDTO
    public var aliases: [String]

    enum CodingKeys: String, CodingKey {
        case id, version, status, revision, edited, events, state, aliases
        case topicId = "topic_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public func toDomain() -> RunDTO { self }
}

/// `RunEventResult`: the response of recordRunEvent.
public struct RunEventResultDTO: Codable, Sendable, Hashable, WireResponse {
    public struct Event: Codable, Sendable, Hashable {
        public var id: String
        public var effect: String
        @RequiredKey public var reason: String?
    }

    public var event: Event
    public var run: RunDTO
    @RequiredKey public var entry: EntryDTO?

    public func toDomain() throws -> RunEventResultDTO {
        _ = try entry?.toDomain()  // the entry's own contract (ids, answers) still holds
        return self
    }
}

// MARK: - Requests

/// `RunEventIn` (recordRunEvent request). Only the fields its type uses are sent (timers.md §3.2).
public struct RunEventInDTO: Codable, Sendable, Hashable {
    public var id: String
    public var type: String
    public var at: String
    public var seg: Int?
    public var step: String?
    public var pauseId: String?
    public var topicId: String?
    public var version: Int?
    public var answers: [String: WireAnswer?]?
    public var notes: String?
    public var meta: [String: String]?
    public var source: String?
    public var device: Device?

    public struct Device: Codable, Sendable, Hashable {
        public var apnsToken: String
        public var liveActivity: Bool

        enum CodingKeys: String, CodingKey {
            case apnsToken = "apns_token"
            case liveActivity = "live_activity"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, at, seg, step, version, answers, notes, meta, source, device
        case pauseId = "pause_id"
        case topicId = "topic_id"
    }
}
