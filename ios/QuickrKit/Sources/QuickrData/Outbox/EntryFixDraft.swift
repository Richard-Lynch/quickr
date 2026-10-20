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

extension OutboxItem {
    /// The draft for fixing this item: only a failed, never-delivered create can be fixed (what
    /// `Outbox.fix` accepts). `questions` type the stored answers (a request body can't tell `7`
    /// from `7.0`). Nil for anything else.
    public func entryFixDraft(questions: [Question]) -> EntryFixDraft? {
        let fixable: Set<OutboxFailureReason> = [.rejected, .topicArchived, .futureTime]
        guard kind == .entryCreate, state == .failed, !maybeDelivered, failureReason.map(fixable.contains) ?? false,
            case .entryCreate(let topic, let body)? = try? OutboxPayload.decode(kind: kind, json: payloadJSON)
        else { return nil }
        let info = lastError
        let problem = info?.body.flatMap { body in
            (try? WireCoding.encoder().encode(body)).flatMap { try? Endpoints.decodeProblem($0) }
        }
        return EntryFixDraft(
            itemId: id, rowVersion: rowVersion, topic: topic, answers: body.domainAnswers(for: questions),
            capturedAt: body.capturedAt, notes: body.notes, problem: problem, message: info?.message)
    }
}
