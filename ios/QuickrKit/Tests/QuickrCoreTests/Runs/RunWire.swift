import Foundation
import QuickrCore

// The vectors' wire shapes (shared/fixtures/run-fold-vectors.json, timing-stats-vectors.json),
// decoded as plain strings, and the domain models written back in that shape, so a case compares
// whole: every instant in the server's form (`RunInstant.format`).

enum RunWire {
    struct Step: Codable, Equatable {
        var key: String
        var label: String

        var domain: TopicTimer.Step { TopicTimer.Step(key: key, label: label) }
    }

    struct Event: Decodable {
        var id: String
        var type: String
        var at: String
        var seg: Int?
        var step: String?
        var pauseId: String?

        enum CodingKeys: String, CodingKey {
            case id, type, at, seg, step
            case pauseId = "pause_id"
        }

        func domain() throws -> RunEvent {
            guard let type = RunEventType(rawValue: type) else { throw WireError("event type \(type)") }
            guard let at = RunInstant.parse(at) else { throw WireError("instant \(at)") }
            return RunEvent(id: id, type: type, at: at, seg: seg, step: step, pauseId: pauseId)
        }
    }

    struct Frozen: Decodable {
        var after: Int
        var reason: String

        func domain() throws -> RunFrozen {
            guard let reason = VoidReason(rawValue: reason) else { throw WireError("reason \(reason)") }
            return RunFrozen(after: after, reason: reason)
        }
    }

    struct Effect: Codable, Equatable {
        var effect: String
        var reason: String?

        init(_ effect: RunEffect) {
            self.effect = effect == .applied ? "applied" : "void"
            reason = effect.reason?.rawValue
        }
    }

    struct Pause: Codable, Equatable {
        var start: String
        var end: String

        init(_ p: RunPause) {
            start = RunInstant.format(p.start)
            end = RunInstant.format(p.end)
        }

        func domain() throws -> RunPause { RunPause(start: try instant(start), end: try instant(end)) }
    }

    struct Segment: Codable, Equatable {
        var kind: String
        var step: String?
        var label: String
        var startedAt: String
        var endedAt: String
        var activeMs: Int
        var pausedMs: Int

        enum CodingKeys: String, CodingKey {
            case kind, step, label
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case activeMs = "active_ms"
            case pausedMs = "paused_ms"
        }

        init(_ s: RunSegment) {
            kind = s.kind.rawValue
            step = s.step
            label = s.label
            startedAt = RunInstant.format(s.startedAt)
            endedAt = RunInstant.format(s.endedAt)
            activeMs = s.activeMs
            pausedMs = s.pausedMs
        }

        func domain() throws -> RunSegment {
            guard let kind = RunSegmentKind(rawValue: kind) else { throw WireError("kind \(kind)") }
            return RunSegment(
                kind: kind, step: step, label: label, startedAt: try instant(startedAt), endedAt: try instant(endedAt),
                activeMs: activeMs, pausedMs: pausedMs)
        }
    }

    struct Open: Codable, Equatable {
        var index: Int
        var kind: String
        var step: String?
        var label: String
        var startedAt: String

        enum CodingKeys: String, CodingKey {
            case index, kind, step, label
            case startedAt = "started_at"
        }

        init(_ o: RunOpenSegment) {
            index = o.index
            kind = o.kind.rawValue
            step = o.step
            label = o.label
            startedAt = RunInstant.format(o.startedAt)
        }
    }

    struct State: Codable, Equatable {
        var status: String
        var startedAt: String
        var endedAt: String?
        var open: Open?
        var nextStep: String?
        var pausedSince: String?
        var segments: [Segment]
        var skipped: [String]
        var pauses: [Pause]
        var effects: [String: Effect]

        enum CodingKeys: String, CodingKey {
            case status, open, segments, skipped, pauses, effects
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case nextStep = "next_step"
            case pausedSince = "paused_since"
        }

        init(_ s: RunState) {
            status = s.status.rawValue
            startedAt = RunInstant.format(s.startedAt)
            endedAt = s.endedAt.map(RunInstant.format)
            open = s.open.map(Open.init)
            nextStep = s.nextStep
            pausedSince = s.pausedSince.map(RunInstant.format)
            segments = s.segments.map(Segment.init)
            skipped = s.skipped
            pauses = s.pauses.map(Pause.init)
            effects = s.effects.mapValues(Effect.init)
        }
    }

    struct WireTiming: Codable, Equatable {
        var startedAt: String
        var endedAt: String
        var activeMs: Int
        var pausedMs: Int
        var complete: Bool
        var edited: Bool
        var segments: [Segment]
        var skipped: [String]
        var pauses: [Pause]

        enum CodingKeys: String, CodingKey {
            case complete, edited, segments, skipped, pauses
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case activeMs = "active_ms"
            case pausedMs = "paused_ms"
        }

        init(_ t: Timing) {
            startedAt = RunInstant.format(t.startedAt)
            endedAt = RunInstant.format(t.endedAt)
            activeMs = t.activeMs
            pausedMs = t.pausedMs
            complete = t.complete
            edited = t.edited
            segments = t.segments.map(Segment.init)
            skipped = t.skipped
            pauses = t.pauses.map(Pause.init)
        }

        func domain() throws -> Timing {
            Timing(
                startedAt: try instant(startedAt), endedAt: try instant(endedAt), activeMs: activeMs,
                pausedMs: pausedMs, complete: complete, edited: edited, segments: try segments.map { try $0.domain() },
                skipped: skipped, pauses: try pauses.map { try $0.domain() })
        }
    }

    struct WireError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static func instant(_ text: String) throws -> Int {
        guard let ms = RunInstant.parse(text) else { throw WireError("instant \(text)") }
        return ms
    }
}
