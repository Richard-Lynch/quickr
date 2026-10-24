import Foundation
import QuickrCore

/// Backoff (outbox.md §5.3), byte-compatible with the PWA's `backoffMs`:
/// `min(5 min, 2 s · 2^(n−1)) × U(0.8, 1.2)`, rounded to the millisecond.
public enum OutboxBackoff {
    public static let base: Duration = .seconds(2)
    public static let cap: Duration = .seconds(300)

    /// `attempts` is the number of attempts already made (≥ 1); `random` is in `[0, 1)`.
    public static func delay(attempts: Int, random: Double) -> Duration {
        let exponential = min(300_000, 2_000 * pow(2, Double(max(0, attempts - 1))))
        return .milliseconds(Int((exponential * (0.8 + random * 0.4)).rounded()))
    }
}

/// Where a response leaves the claimed item: outbox.md §5.1 and §5.2 step 1, after the step 0
/// identity checks that `APIClassifier` already applied. Pure, so the table is tested row by row.
/// Applied only after the sender check passes (S2).
public enum OutboxResolution: Sendable, Hashable {
    /// A definitive success: the atomic ack (sync-protocol.md §6).
    case ack(OutboxSuccess)
    /// The entity is gone: tombstone it, retire the item when a later `entry.delete` exists,
    /// otherwise fail it `deleted_elsewhere` (§5.2 `entry_deleted`, `entry.update` 404).
    case entityGone
    /// Remove without effect. `pull` asks the coordinator to run (archive 404).
    case retire(pull: Bool)
    case fail(OutboxFailureReason, pull: Bool)
    /// Retry-class (S4); `maybeDelivered` sets the sticky flag (S3).
    case retry(maybeDelivered: Bool)
    /// §7.4: refetch, rebase and resend.
    case rebase
    /// A start refused because the server already knows its id (409 `event_conflict` or
    /// `id_conflict`, timers.md §10.2): the same reminder started on another device, or the PWA.
    /// `Outbox` reads the run (or entry) with that id: one of the start's topic is "started
    /// elsewhere" and resolves the item; anything else fails it `rejected`, as before.
    case startKnown
    /// `startKnown` found an entry of the start's topic with the start's id: the reminder was
    /// already logged, so the run never existed. The start is retired with every other item of the
    /// run (answers fail `logged_elsewhere` instead, so they aren't lost silently); a pull follows.
    case loggedElsewhere
    /// 409 `server_mismatch` / `epoch_mismatch`: nothing executed; restore the pre-claim state.
    case restore(OutboxMismatch)
    /// Mismatched or missing headers on a response that may have executed: `uncertain`.
    case mismatchUncertain(OutboxMismatch)

    /// `runEvent` is a `run.event` item's event type (a start's 404 differs from the others').
    public static func resolve(
        _ kind: OutboxKind, _ outcome: APIOutcome<OutboxSuccess>, runEvent: RunEventType? = nil
    ) -> OutboxResolution {
        switch outcome {
        case .identityMismatch(let evidence):
            return evidence.mayHaveExecuted ? .mismatchUncertain(.identity) : .restore(.identity)
        case .epochMismatch(let evidence):
            return evidence.mayHaveExecuted ? .mismatchUncertain(.epoch) : .restore(.epoch)
        case .success(let value):
            return .ack(value)
        case .retryable:
            return .retry(maybeDelivered: false)
        case .uncertain:
            return .retry(maybeDelivered: true)
        case .entryDeleted:
            switch kind {
            case .entryCreate, .entryUpdate: return .entityGone
            // A delete whose id is already reserved is done.
            case .entryDelete: return .ack(.empty)
            case .topicArchive, .topicUnarchive, .runEvent: return .fail(.rejected, pull: false)
            }
        case .notFound:
            switch kind {
            case .entryCreate: return .fail(.topicMissing, pull: true)
            case .entryUpdate: return .entityGone
            case .entryDelete: return .ack(.empty)
            case .topicArchive: return .retire(pull: true)
            case .topicUnarchive: return .fail(.deletedElsewhere, pull: true)
            // timers.md §8.1: the run is gone (a start's 404 is its topic's, as for a create).
            case .runEvent:
                return runEvent == .start ? .fail(.topicMissing, pull: true) : .fail(.deletedElsewhere, pull: true)
            }
        case .staleRevision:
            switch kind {
            case .entryUpdate, .topicArchive, .topicUnarchive: return .rebase
            // Creates, deletes and run events never send `expected_revision`; the server can't say this.
            case .entryCreate, .entryDelete, .runEvent: return .fail(.rejected, pull: false)
            }
        case .terminal(let status, let problem):
            // timers.md §8.1: the run's topic was deleted; nothing can come of the event. A start's
            // known id is checked (`startKnown`). Every other refusal (`topic_not_timed`,
            // `topic_archived`, a non-start's `event_conflict`, a finish's `run_open`, any 422)
            // fails it with its payload kept.
            if kind == .runEvent, status == 409, problem?.code == .runDeleted { return .retire(pull: true) }
            if kind == .runEvent, runEvent == .start, status == 409,
                problem?.code == .eventConflict || problem?.code == .idConflict
            {
                return .startKnown
            }
            if kind == .entryCreate, status == 409, problem?.code == .topicArchived {
                return .fail(.topicArchived, pull: false)
            }
            return .fail(.rejected, pull: false)
        }
    }
}

/// Which `sync_state` flag a mismatch sets (sync-protocol.md §5.6, §8.3).
public enum OutboxMismatch: Sendable, Hashable {
    /// `identity_mismatch`
    case identity
    /// `epoch_suspect`
    case epoch

    var column: String {
        switch self {
        case .identity: "identity_mismatch"
        case .epoch: "epoch_suspect"
        }
    }
}

/// User-facing texts the outbox writes itself (the rest come from `APIResponse.errorInfo`).
enum OutboxMessage {
    static let topicArchived = "Topic is archived. Unarchive it to sync this entry."
    static let conflict = "Changed on another device — review and retry"
    static let deletedElsewhere = "Deleted on another device"
    static let loggedElsewhere = "Already logged on another device"
    static let entryDeleted = "This entry was deleted"
    static let topicMissing = "Topic not found"

    static func futureTime(hours: Int) -> String { "Can’t be more than \(hours) hours in the future" }
    static let beforeMinimum = "Can’t be before 2000"
}
