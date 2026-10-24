import Foundation
import Observation
import QuickrCore

/// The taps of the app's run surfaces, the home tile and the run screen (timers.md §11.1, §11.2):
/// each goes through the write façade (`RunWrites`, via the session), with two guards against a
/// double tap reading as two different actions.
///
/// - **Cooldown.** After a tap on a topic's run controls, Start included, every other tap on that
///   topic within `cooldown` (450 ms) is ignored. The buttons change under the finger ("Start"
///   becomes "Next: Shower", "Next: Teeth" becomes Stop on the last step), so a second tap would
///   otherwise land on a different control than the one the user meant. One open run per topic,
///   so the topic keys it: the new run of a Start is covered too.
/// - **Expect.** Each tap carries what the control showed (`RunTapExpect`), captured at render; a
///   tap whose target has moved since (it went stale behind an earlier queued one) enqueues
///   nothing (`RunTapTarget.expect`).
///
/// Shared by every tile and run screen (it lives in the app environment), so the cooldown holds
/// across a re-render and across screens.
@MainActor @Observable
public final class RunActions {
    /// The window after a tap in which the topic's other taps are ignored.
    public static let cooldown: Duration = .milliseconds(450)

    /// What Stop leads to.
    public enum StopOutcome: Sendable, Hashable {
        /// The version has questions, or they aren't known: open the answers form (§11.2).
        case details(runId: String)
        /// No questions: the stop made the entry. `totalMs` is the run's active time at the tap.
        case saved(topicName: String, totalMs: Int)
    }

    /// The façade's calls, then a flush: `AppSession.startRun` and `tapRun`.
    public struct Writer: Sendable {
        public var start: @Sendable (TopicRef, Int) async throws -> RunStartResult
        public var tap: @Sendable (RunTapType, String, RunTapTarget) async throws -> OutboxEnqueueResult?

        public init(
            start: @escaping @Sendable (TopicRef, Int) async throws -> RunStartResult,
            tap: @escaping @Sendable (RunTapType, String, RunTapTarget) async throws -> OutboxEnqueueResult?
        ) {
            self.start = start
            self.tap = tap
        }
    }

    /// A tap is being written.
    public private(set) var busy = false
    /// The last tap that failed to be written (not one the server refused later), until the next.
    public private(set) var lastFailure: String?

    @ObservationIgnored private let writer: () -> Writer?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let cooldown: Duration
    /// When each topic's controls were last tapped.
    @ObservationIgnored private var lastTap: [String: ContinuousClock.Instant] = [:]

    /// - Parameter writer: the active session's writer, read at each tap; nil before a store is
    ///   bound (the tap does nothing).
    public init(
        writer: @escaping () -> Writer?, cooldown: Duration = RunActions.cooldown,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.writer = writer
        self.cooldown = cooldown
        self.now = now
    }

    /// Whether a tap on `topicId`'s controls now is inside its cooldown; if not, it starts one.
    func coolingDown(_ topicId: String) -> Bool {
        let topicId = topicId.lowercased()
        let at = now()
        if let last = lastTap[topicId], at - last < cooldown { return true }
        lastTap[topicId] = at
        return false
    }

    /// Start (idle tile or screen): a run pinned to `version`, the topic's current one. Nil when
    /// ignored (cooldown) or the write failed.
    @discardableResult
    public func start(topic: TopicRef, version: Int) async -> RunStartResult? {
        guard !coolingDown(topic.id), let writer = writer() else { return nil }
        return await guarded { try await writer.start(topic, version) }
    }

    /// One tap on `run`'s controls (Next, Lap, Skip, Pause, Resume). `expect` is what the control
    /// showed. Nil when ignored or nothing was enqueued.
    @discardableResult
    public func tap(_ type: RunTapType, run: LocalRun, expect: RunTapExpect) async -> OutboxEnqueueResult? {
        guard !coolingDown(run.topicId.wireString), let writer = writer() else { return nil }
        return await guarded { try await writer.tap(type, run.id, .expect(expect)) } ?? nil
    }

    /// Stop: ends the clock at the tap, without answers (§3.6). Then the answers form if the
    /// run's version has questions or they aren't known, else "Saved". Nil when ignored or
    /// nothing was enqueued.
    public func stop(run: LocalRun, topicName: String, expect: RunTapExpect) async -> StopOutcome? {
        guard !coolingDown(run.topicId.wireString), let writer = writer() else { return nil }
        guard let result = await guarded({ try await writer.tap(.stop, run.id, .expect(expect)) }) ?? nil,
            case .appended(let item) = result
        else { return nil }
        if run.hasQuestions != false { return .details(runId: run.id) }
        let at = (try? item.runEventPayload()).flatMap { RunInstant.parse($0.event.at) } ?? run.state.startedAt
        return .saved(topicName: topicName, totalMs: RunPresentation.activeMs(run.state, now: at))
    }

    /// Discard, after the confirmation. True when it was enqueued (or dropped the never-sent run,
    /// K6). Not cooled down: it follows a confirmation, never a double tap.
    @discardableResult
    public func discard(run: LocalRun) async -> Bool {
        guard let writer = writer() else { return false }
        let result = await guarded { try await writer.tap(.discard, run.id, .current) } ?? nil
        return result != nil
    }

    private func guarded<T: Sendable>(_ body: () async throws -> T) async -> T? {
        busy = true
        defer { busy = false }
        do {
            let value = try await body()
            lastFailure = nil
            return value
        } catch {
            lastFailure = String(describing: error)
            return nil
        }
    }
}

extension RunActions.Writer {
    /// The session's `startRun` and `tapRun`: the façade, then a flush.
    @MainActor public init(session: AppSession) {
        self.init(
            start: { topic, version in try await session.startRun(topic: topic, version: version) },
            tap: { type, runId, target in try await session.tapRun(type, runId: runId, target: target) })
    }
}
