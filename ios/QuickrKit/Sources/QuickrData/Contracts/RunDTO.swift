import Foundation
import QuickrCore

// Runs of timed topics (docs/specs/timers.md §3), mapped to QuickrCore's run models. Instants
// are parsed to integer epoch milliseconds (`RunInstant`) and never go through `Date`
// (timers.md §2.3); an instant, type, status or effect outside the contract fails the mapping.

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

    public func toDomain() throws -> Run {
        Run(
            id: try .wire(id, "run.id"), topicId: try .wire(topicId, "run.topic_id"), version: version,
            status: try RunWire.status(status, "run.status"), revision: revision,
            startedAt: try RunWire.instant(startedAt, "run.started_at"),
            endedAt: try endedAt.map { try RunWire.instant($0, "run.ended_at") }, edited: edited,
            events: try events.map { try $0.toDomain() }, state: try state.toDomain(),
            aliases: try aliases.map { try .wire($0, "run.aliases") })
    }
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

    public func toDomain() throws -> RunEventResult {
        RunEventResult(
            eventId: event.id, effect: try RunWire.effect(event.effect, event.reason, "event"), run: try run.toDomain(),
            entry: try entry?.toDomain())
    }
}

// MARK: - Domain mapping

/// Parsing of the run wire values, failing with `ContractError`.
enum RunWire {
    static func instant(_ text: String, _ field: String) throws -> Int {
        guard let ms = RunInstant.parse(text) else { throw ContractError.invalid("\(field): not an instant: \(text)") }
        return ms
    }

    static func status(_ text: String, _ field: String) throws -> RunStatus {
        guard let status = RunStatus(rawValue: text) else { throw ContractError.invalid("\(field): \(text)") }
        return status
    }

    static func kind(_ text: String, step: String?, _ field: String) throws -> RunSegmentKind {
        guard let kind = RunSegmentKind(rawValue: text), (kind == .step) == (step != nil) else {
            throw ContractError.invalid("\(field): kind \(text) with step \(step ?? "null")")
        }
        return kind
    }

    static func effect(_ effect: String, _ reason: String?, _ field: String) throws -> RunEffect {
        switch (effect, reason) {
        case ("applied", nil): return .applied
        case ("void", let reason?):
            guard let reason = VoidReason(rawValue: reason) else {
                throw ContractError.invalid("\(field): unknown void reason \(reason)")
            }
            return .void(reason)
        default: throw ContractError.invalid("\(field): effect \(effect) with reason \(reason ?? "null")")
        }
    }
}

extension TimingSegmentDTO {
    public func toDomain() throws -> RunSegment {
        RunSegment(
            kind: try RunWire.kind(kind, step: step, "segment.kind"), step: step, label: label,
            startedAt: try RunWire.instant(startedAt, "segment.started_at"),
            endedAt: try RunWire.instant(endedAt, "segment.ended_at"), activeMs: activeMs, pausedMs: pausedMs)
    }
}

extension TimingPauseDTO {
    public func toDomain() throws -> RunPause {
        RunPause(start: try RunWire.instant(start, "pause.start"), end: try RunWire.instant(end, "pause.end"))
    }
}

extension TimingDTO {
    public func toDomain() throws -> Timing {
        Timing(
            startedAt: try RunWire.instant(startedAt, "timing.started_at"),
            endedAt: try RunWire.instant(endedAt, "timing.ended_at"), activeMs: activeMs, pausedMs: pausedMs,
            complete: complete, edited: edited, segments: try segments.map { try $0.toDomain() }, skipped: skipped,
            pauses: try pauses.map { try $0.toDomain() })
    }
}

extension RunEventDTO {
    public func toDomain() throws -> Run.StoredEvent {
        guard let type = RunEventType(rawValue: type) else { throw ContractError.invalid("run event type \(type)") }
        return Run.StoredEvent(
            event: RunEvent(
                id: id, type: type, at: try RunWire.instant(at, "run_event.at"), seg: seg, step: step, pauseId: pauseId),
            arrival: arrival, effect: try RunWire.effect(effect, reason, "run_event \(id)"), source: source)
    }
}

extension RunOpenSegmentDTO {
    public func toDomain() throws -> RunOpenSegment {
        RunOpenSegment(
            index: index, kind: try RunWire.kind(kind, step: step, "open.kind"), step: step, label: label,
            startedAt: try RunWire.instant(startedAt, "open.started_at"))
    }
}

extension RunStateDTO {
    public func toDomain() throws -> RunState {
        RunState(
            status: try RunWire.status(status, "state.status"),
            startedAt: try RunWire.instant(startedAt, "state.started_at"),
            endedAt: try endedAt.map { try RunWire.instant($0, "state.ended_at") }, open: try open?.toDomain(),
            nextStep: nextStep, pausedSince: try pausedSince.map { try RunWire.instant($0, "state.paused_since") },
            segments: try segments.map { try $0.toDomain() }, skipped: skipped,
            pauses: try pauses.map { try $0.toDomain() },
            effects: try effects.mapValues { try RunWire.effect($0.effect, $0.reason, "state.effects") })
    }
}

// MARK: - From the domain

// The wire shapes of the domain values, for the store's JSON columns (`run.run_json`,
// `entry.timing_json`): `toDomain()` reads them back unchanged (every instant is a whole
// millisecond, which `RunInstant.format` writes exactly).

extension RunWire {
    /// `(effect, reason)` as the wire writes them.
    static func wire(_ effect: RunEffect) -> (effect: String, reason: String?) {
        switch effect {
        case .applied: ("applied", nil)
        case .void(let reason): ("void", reason.rawValue)
        }
    }
}

extension TimingSegmentDTO {
    public init(_ segment: RunSegment) {
        self.init(
            kind: segment.kind.rawValue, step: segment.step, label: segment.label,
            startedAt: RunInstant.format(segment.startedAt), endedAt: RunInstant.format(segment.endedAt),
            activeMs: segment.activeMs, pausedMs: segment.pausedMs)
    }
}

extension TimingPauseDTO {
    public init(_ pause: RunPause) {
        self.init(start: RunInstant.format(pause.start), end: RunInstant.format(pause.end))
    }
}

extension TimingDTO {
    public init(_ timing: Timing) {
        self.init(
            startedAt: RunInstant.format(timing.startedAt), endedAt: RunInstant.format(timing.endedAt),
            activeMs: timing.activeMs, pausedMs: timing.pausedMs, complete: timing.complete, edited: timing.edited,
            segments: timing.segments.map(TimingSegmentDTO.init), skipped: timing.skipped,
            pauses: timing.pauses.map(TimingPauseDTO.init))
    }
}

extension RunEventDTO {
    public init(_ stored: Run.StoredEvent) {
        let effect = RunWire.wire(stored.effect)
        self.init(
            id: stored.event.id, type: stored.event.type.rawValue, at: RunInstant.format(stored.event.at),
            seg: stored.event.seg, step: stored.event.step, pauseId: stored.event.pauseId, arrival: stored.arrival,
            effect: effect.effect, reason: effect.reason, source: stored.source)
    }
}

extension RunOpenSegmentDTO {
    public init(_ open: RunOpenSegment) {
        self.init(
            index: open.index, kind: open.kind.rawValue, step: open.step, label: open.label,
            startedAt: RunInstant.format(open.startedAt))
    }
}

extension RunStateDTO {
    public init(_ state: RunState) {
        self.init(
            status: state.status.rawValue, startedAt: RunInstant.format(state.startedAt),
            endedAt: state.endedAt.map(RunInstant.format), open: state.open.map(RunOpenSegmentDTO.init),
            nextStep: state.nextStep, pausedSince: state.pausedSince.map(RunInstant.format),
            segments: state.segments.map(TimingSegmentDTO.init), skipped: state.skipped,
            pauses: state.pauses.map(TimingPauseDTO.init),
            effects: state.effects.mapValues { effect in
                let wire = RunWire.wire(effect)
                return RunEventEffectDTO(effect: wire.effect, reason: wire.reason)
            })
    }
}

extension RunDTO {
    public init(_ run: Run) {
        self.init(
            id: run.id.wireString, topicId: run.topicId.wireString, version: run.version, status: run.status.rawValue,
            revision: run.revision, startedAt: RunInstant.format(run.startedAt),
            endedAt: run.endedAt.map(RunInstant.format), edited: run.edited, events: run.events.map(RunEventDTO.init),
            state: RunStateDTO(run.state), aliases: run.aliases.map(\.wireString))
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
