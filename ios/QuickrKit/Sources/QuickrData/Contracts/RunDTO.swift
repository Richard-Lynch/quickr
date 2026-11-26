import Foundation
import QuickrCore

// Runs of timed topics (docs/specs/timers.md §3, timers2.md §3.3 and §7.1), mapped to
// QuickrCore's run models. Instants are parsed to integer epoch milliseconds (`RunInstant`) and
// never go through `Date` (timers.md §2.3); an instant, type, status or effect outside the
// contract fails the mapping.
//
// A stored timing's v2 fields (`terminal_id`, a segment's `lap_type`, `event_id` and
// `opened_by`, a pause's `id`) are plain optionals: absent on a pre-v2 stored timing (timers2.md
// §3.3). A `RunState`'s own v2 fields are required keys. `RunEventOut.target` is a plain optional
// until the server's write path serves it (§7.1).

/// One segment of a finished run (`TimingSegment`).
public struct TimingSegmentDTO: Codable, Sendable, Hashable {
    public var kind: String
    @RequiredKey public var step: String?
    public var label: String
    public var startedAt: String
    public var endedAt: String
    public var activeMs: Int
    public var pausedMs: Int
    public var lapType: String?
    public var eventId: String?
    public var openedBy: String?

    enum CodingKeys: String, CodingKey {
        case kind, step, label
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case activeMs = "active_ms"
        case pausedMs = "paused_ms"
        case lapType = "lap_type"
        case eventId = "event_id"
        case openedBy = "opened_by"
    }
}

/// `TimingPause`.
public struct TimingPauseDTO: Codable, Sendable, Hashable {
    public var start: String
    public var end: String
    public var id: String?
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
    public var terminalId: String?

    enum CodingKeys: String, CodingKey {
        case complete, edited, segments, skipped, pauses
        case terminalId = "terminal_id"
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
    /// The resolved target of a reopen or remove.
    public var target: String?

    enum CodingKeys: String, CodingKey {
        case id, type, at, seg, step, arrival, effect, reason, source, target
        case pauseId = "pause_id"
    }
}

extension CodingUserInfoKey {
    /// Set by the store's JSON decoder (`StoreJSON.decode`): the JSON was written by this app,
    /// possibly by a build from before a field existed.
    static let storedJSON = CodingUserInfoKey(rawValue: "quickr.storedJSON")!
}

extension Decoder {
    var isStoredJSON: Bool { userInfo[.storedJSON] as? Bool == true }
}

/// `RunOpenSegment`.
public struct RunOpenSegmentDTO: Codable, Sendable, Hashable {
    public var index: Int
    public var kind: String
    @RequiredKey public var step: String?
    public var label: String
    public var startedAt: String
    @RequiredKey public var lapType: String?

    enum CodingKeys: String, CodingKey {
        case index, kind, step, label
        case startedAt = "started_at"
        case lapType = "lap_type"
    }

    public init(index: Int, kind: String, step: String?, label: String, startedAt: String, lapType: String?) {
        self.index = index
        self.kind = kind
        self.step = step
        self.label = label
        self.startedAt = startedAt
        self.lapType = lapType
    }

    /// `lap_type` is required on the wire; a run cached before fold v4 lacks it (untyped).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        kind = try c.decode(String.self, forKey: .kind)
        _step = try c.decode(RequiredKey<String>.self, forKey: .step)
        label = try c.decode(String.self, forKey: .label)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        _lapType =
            decoder.isStoredJSON && !c.contains(.lapType)
            ? RequiredKey(wrappedValue: nil) : try c.decode(RequiredKey<String>.self, forKey: .lapType)
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
    @RequiredKey public var terminalId: String?
    @RequiredKey public var nextLapType: String?
    public var lapCount: Int

    enum CodingKeys: String, CodingKey {
        case status, open, segments, skipped, pauses, effects
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case nextStep = "next_step"
        case pausedSince = "paused_since"
        case terminalId = "terminal_id"
        case nextLapType = "next_lap_type"
        case lapCount = "lap_count"
    }

    public init(
        status: String, startedAt: String, endedAt: String?, open: RunOpenSegmentDTO?, nextStep: String?,
        pausedSince: String?, segments: [TimingSegmentDTO], skipped: [String], pauses: [TimingPauseDTO],
        effects: [String: RunEventEffectDTO], terminalId: String?, nextLapType: String?, lapCount: Int
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
        self.terminalId = terminalId
        self.nextLapType = nextLapType
        self.lapCount = lapCount
    }

    /// The v2 fields are required on the wire. A run cached before fold v4 (store JSON) lacks
    /// them: no terminal id (it can't be reopened from here until the feed refreshes it), no lap
    /// types, and the lap count of its segments.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        _endedAt = try c.decode(RequiredKey<String>.self, forKey: .endedAt)
        _open = try c.decode(RequiredKey<RunOpenSegmentDTO>.self, forKey: .open)
        _nextStep = try c.decode(RequiredKey<String>.self, forKey: .nextStep)
        _pausedSince = try c.decode(RequiredKey<String>.self, forKey: .pausedSince)
        segments = try c.decode([TimingSegmentDTO].self, forKey: .segments)
        skipped = try c.decode([String].self, forKey: .skipped)
        pauses = try c.decode([TimingPauseDTO].self, forKey: .pauses)
        effects = try c.decode([String: RunEventEffectDTO].self, forKey: .effects)
        let legacy = decoder.isStoredJSON && !c.contains(.lapCount)
        if legacy {
            _terminalId = RequiredKey(wrappedValue: nil)
            _nextLapType = RequiredKey(wrappedValue: nil)
            lapCount = segments.count { $0.kind == "lap" }
        } else {
            _terminalId = try c.decode(RequiredKey<String>.self, forKey: .terminalId)
            _nextLapType = try c.decode(RequiredKey<String>.self, forKey: .nextLapType)
            lapCount = try c.decode(Int.self, forKey: .lapCount)
        }
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

    /// The state's `reopenId` (not on the wire) comes from the events: the open reopen
    /// transaction a discard would revert (`RunFold.openReopen`).
    public func toDomain() throws -> Run {
        let events = try events.map { try $0.toDomain() }
        var state = try state.toDomain()
        state.reopenId = RunFold.openReopen(
            events: events.sorted { $0.arrival < $1.arrival }.map(\.event), effects: state.effects,
            status: state.status)
        return Run(
            id: try .wire(id, "run.id"), topicId: try .wire(topicId, "run.topic_id"), version: version,
            status: try RunWire.status(status, "run.status"), revision: revision,
            startedAt: try RunWire.instant(startedAt, "run.started_at"),
            endedAt: try endedAt.map { try RunWire.instant($0, "run.ended_at") }, edited: edited, events: events,
            state: state, aliases: try aliases.map { try .wire($0, "run.aliases") })
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

    static func openedBy(_ text: String?, _ field: String) throws -> RunOpenedBy? {
        guard let text else { return nil }
        guard let opened = RunOpenedBy(rawValue: text) else { throw ContractError.invalid("\(field): \(text)") }
        return opened
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
            endedAt: try RunWire.instant(endedAt, "segment.ended_at"), activeMs: activeMs, pausedMs: pausedMs,
            lapType: lapType, eventId: eventId, openedBy: try RunWire.openedBy(openedBy, "segment.opened_by"))
    }
}

extension TimingPauseDTO {
    public func toDomain() throws -> RunPause {
        RunPause(start: try RunWire.instant(start, "pause.start"), end: try RunWire.instant(end, "pause.end"), id: id)
    }
}

extension TimingDTO {
    public func toDomain() throws -> Timing {
        Timing(
            startedAt: try RunWire.instant(startedAt, "timing.started_at"),
            endedAt: try RunWire.instant(endedAt, "timing.ended_at"), activeMs: activeMs, pausedMs: pausedMs,
            complete: complete, edited: edited, segments: try segments.map { try $0.toDomain() }, skipped: skipped,
            pauses: try pauses.map { try $0.toDomain() }, terminalId: terminalId)
    }
}

extension RunEventDTO {
    public func toDomain() throws -> Run.StoredEvent {
        guard let type = RunEventType(rawValue: type) else { throw ContractError.invalid("run event type \(type)") }
        return Run.StoredEvent(
            event: RunEvent(
                id: id, type: type, at: try RunWire.instant(at, "run_event.at"), seg: seg, step: step, pauseId: pauseId,
                target: target),
            arrival: arrival, effect: try RunWire.effect(effect, reason, "run_event \(id)"), source: source)
    }
}

extension RunOpenSegmentDTO {
    public func toDomain() throws -> RunOpenSegment {
        RunOpenSegment(
            index: index, kind: try RunWire.kind(kind, step: step, "open.kind"), step: step, label: label,
            startedAt: try RunWire.instant(startedAt, "open.started_at"), lapType: lapType)
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
            effects: try effects.mapValues { try RunWire.effect($0.effect, $0.reason, "state.effects") },
            terminalId: terminalId, nextLapType: nextLapType, lapCount: lapCount)
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
            activeMs: segment.activeMs, pausedMs: segment.pausedMs, lapType: segment.lapType,
            eventId: segment.eventId, openedBy: segment.openedBy?.rawValue)
    }
}

extension TimingPauseDTO {
    public init(_ pause: RunPause) {
        self.init(start: RunInstant.format(pause.start), end: RunInstant.format(pause.end), id: pause.id)
    }
}

extension TimingDTO {
    public init(_ timing: Timing) {
        self.init(
            startedAt: RunInstant.format(timing.startedAt), endedAt: RunInstant.format(timing.endedAt),
            activeMs: timing.activeMs, pausedMs: timing.pausedMs, complete: timing.complete, edited: timing.edited,
            segments: timing.segments.map(TimingSegmentDTO.init), skipped: timing.skipped,
            pauses: timing.pauses.map(TimingPauseDTO.init), terminalId: timing.terminalId)
    }
}

extension RunEventDTO {
    public init(_ stored: Run.StoredEvent) {
        let effect = RunWire.wire(stored.effect)
        self.init(
            id: stored.event.id, type: stored.event.type.rawValue, at: RunInstant.format(stored.event.at),
            seg: stored.event.seg, step: stored.event.step, pauseId: stored.event.pauseId, arrival: stored.arrival,
            effect: effect.effect, reason: effect.reason, source: stored.source, target: stored.event.target)
    }
}

extension RunOpenSegmentDTO {
    public init(_ open: RunOpenSegment) {
        self.init(
            index: open.index, kind: open.kind.rawValue, step: open.step, label: open.label,
            startedAt: RunInstant.format(open.startedAt), lapType: open.lapType)
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
            }, terminalId: state.terminalId, nextLapType: state.nextLapType, lapCount: state.lapCount)
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
    /// A reopen's or remove's target (timers2.md §7.1); nil for a reopen means "the current
    /// terminal".
    public var target: String?
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

        public init(apnsToken: String, liveActivity: Bool) {
            self.apnsToken = apnsToken
            self.liveActivity = liveActivity
        }

        enum CodingKeys: String, CodingKey {
            case apnsToken = "apns_token"
            case liveActivity = "live_activity"
        }
    }

    public init(
        id: String, type: String, at: String, seg: Int? = nil, step: String? = nil, pauseId: String? = nil,
        target: String? = nil, topicId: String? = nil, version: Int? = nil, answers: [String: WireAnswer?]? = nil,
        notes: String? = nil,
        meta: [String: String]? = nil, source: String? = nil, device: Device? = nil
    ) {
        self.id = id
        self.type = type
        self.at = at
        self.seg = seg
        self.step = step
        self.pauseId = pauseId
        self.target = target
        self.topicId = topicId
        self.version = version
        self.answers = answers
        self.notes = notes
        self.meta = meta
        self.source = source
        self.device = device
    }

    enum CodingKeys: String, CodingKey {
        case id, type, at, seg, step, version, answers, notes, meta, source, device, target
        case pauseId = "pause_id"
        case topicId = "topic_id"
    }
}
