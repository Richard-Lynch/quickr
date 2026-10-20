import Foundation
import QuickrCore

/// A rejected entry, ready for the record screen's fix mode (the PWA's `/t/:ref/record?fix=<id>`):
/// what was sent, and why the server refused it.
public struct EntryFixDraft: Sendable, Hashable {
    /// The outbox item's id (the entry's id for a create).
    public var itemId: String
    /// For the compare-and-set of `Outbox.fix` (an edit elsewhere in between fails it).
    public var rowVersion: Int
    public var topic: TopicRef
    public var answers: [String: AnswerValue]
    public var capturedAt: Date?
    public var notes: String?
    /// The server's `Problem`, when the failure carried one (a 4xx with a body).
    public var problem: Problem?
    /// The failure's message, for when there's no `Problem` to put on the fields.
    public var message: String?
}

extension OutboxErrorInfo {
    /// The server's `Problem`, when the error body was one (a 4xx from quickR).
    public var problem: Problem? {
        body.flatMap { body in (try? WireCoding.encoder().encode(body)).flatMap { try? Endpoints.decodeProblem($0) } }
    }
}

extension OutboxItem {
    /// Why a failed item was refused: the server's `Problem` (when its error body had one) and the
    /// message. Nil without a recorded error.
    public var failureDetails: (problem: Problem?, message: String)? {
        guard let info = lastError else { return nil }
        return (info.problem, info.message)
    }

    /// The draft for fixing this item: only a failed, never-delivered create can be fixed (what
    /// `Outbox.fix` accepts). `questions` type the stored answers (a request body can't tell `7`
    /// from `7.0`). Nil for anything else.
    public func entryFixDraft(questions: [Question]) -> EntryFixDraft? {
        let fixable: Set<OutboxFailureReason> = [.rejected, .topicArchived, .futureTime]
        guard kind == .entryCreate, state == .failed, !maybeDelivered, failureReason.map(fixable.contains) ?? false,
            case .entryCreate(let topic, let body)? = try? OutboxPayload.decode(kind: kind, json: payloadJSON)
        else { return nil }
        let failure = failureDetails
        return EntryFixDraft(
            itemId: id, rowVersion: rowVersion, topic: topic, answers: body.domainAnswers(for: questions),
            capturedAt: body.capturedAt, notes: body.notes, problem: failure?.problem, message: failure?.message)
    }
}

/// A refused edit of an entry, ready for the edit screen's fix mode (outbox.md §11: Fix covers a
/// failed `entry.update` too): the changed fields that were sent, and why the server refused them.
public struct EntryUpdateFixDraft: Sendable, Hashable {
    /// The outbox item's id.
    public var itemId: String
    /// For the compare-and-set of `Outbox.fix`.
    public var rowVersion: Int
    public var entryId: String
    /// The answers the edit set (nil clears one), typed by the entry's version.
    public var answers: [String: AnswerValue?]?
    public var capturedAt: Date?
    public var notes: String?
    public var source: String?
    public var problem: Problem?
    public var message: String?
}

extension OutboxItem {
    /// The draft for fixing this refused edit: a failed, never-delivered `entry.update` refused for
    /// a reason Fix can address (what `Outbox.fix` accepts). `questions` are the entry's version's.
    public func entryUpdateFixDraft(questions: [Question]) -> EntryUpdateFixDraft? {
        let fixable: Set<OutboxFailureReason> = [.rejected, .topicArchived, .futureTime]
        guard kind == .entryUpdate, state == .failed, !maybeDelivered, failureReason.map(fixable.contains) ?? false,
            case .entryUpdate(let entryId, _, let patch)? = try? OutboxPayload.decode(kind: kind, json: payloadJSON)
        else { return nil }
        let failure = failureDetails
        return EntryUpdateFixDraft(
            itemId: id, rowVersion: rowVersion, entryId: entryId, answers: patch.domainAnswers(for: questions),
            capturedAt: patch.capturedAt, notes: patch.notes, source: patch.source, problem: failure?.problem,
            message: failure?.message)
    }
}
