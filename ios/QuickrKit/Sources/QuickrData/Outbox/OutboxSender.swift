import Foundation
import QuickrCore

/// One request the outbox makes (outbox.md §1, and the §7.4 refetch). Built at send time from the
/// item; the topic is always addressed by id.
public enum OutboxOperation: Sendable, Hashable {
    /// `POST /topics/{topic_id}/entries`; `body.id` is the item id and `body.source` is set.
    case createEntry(topicId: String, body: EntryCreateDTO)
    /// `PATCH /entries/{id}`; `body.expectedRevision` is the item's `base_revision`.
    case updateEntry(entryId: UUID, body: EntryUpdateDTO)
    case deleteEntry(entryId: UUID)
    case archiveTopic(topicId: String, expectedRevision: Int?)
    case unarchiveTopic(topicId: String, expectedRevision: Int?)
    /// `POST /runs/{run_id}/events` (timers.md §8.1); `body.id` is the item id and `body.source` is
    /// set.
    case recordRunEvent(runId: UUID, body: RunEventInDTO)
    /// The §7.4 refetch. A read: no precondition headers, but the response is still checked.
    case getEntry(entryId: UUID)
    case getTopic(topicId: String)
    /// The check of a start refused as a known id (timers.md §10.2): the run that id resolves to.
    case getRun(runId: UUID)
}

public struct OutboxRequest: Sendable, Hashable {
    public var operation: OutboxOperation
    /// `(store.server_id, claim_epoch)`: the Expect headers of a mutation (outbox.md §4), and the
    /// identity every response is checked against (§5.2 step 0).
    public var expecting: ServerIdentity
    /// 15 s, capped by the remaining budget (outbox.md §4).
    public var timeout: Duration

    public init(operation: OutboxOperation, expecting: ServerIdentity, timeout: Duration) {
        self.operation = operation
        self.expecting = expecting
        self.timeout = timeout
    }
}

/// The decoded body of a definitive success: `EntryOut`, `TopicDetail`, or nothing (DELETE).
public enum OutboxSuccess: Sendable, Hashable {
    case entry(Entry)
    case topic(Topic)
    /// A `RunEventResult` (timers.md §3.2), void effects included.
    case runEvent(RunEventResult)
    /// A `getRun` read; never acked as is.
    case run(Run)
    case empty
}

/// The outbox's only way to the network. `APIClient` satisfies it (below); tests may script it.
///
/// A sender never throws: every failure, including a request it refused to build, is an
/// `APIOutcome` (outbox.md §5.1). It must never follow redirects, and it **must honour task
/// cancellation promptly** (a budget expiry or an expiration handler cancels the request, §10),
/// as `URLSession` does. A flusher stops listening to a sender that doesn't after its shutdown
/// grace, so the flush still ends in time, but that sender's task, and whatever it retains,
/// lives on until it returns: a sender that ignores cancellation leaks one task per abandoned
/// request.
public protocol OutboxSender: Sendable {
    func send(_ request: OutboxRequest) async -> APIResponse<OutboxSuccess>
}

extension APIClient: OutboxSender {
    public func send(_ request: OutboxRequest) async -> APIResponse<OutboxSuccess> {
        let options = RequestOptions(expecting: request.expecting, timeout: request.timeout)
        do {
            switch request.operation {
            case .createEntry(let topicId, let body):
                return try await createEntry(ref: topicId, body, options: options).mapSuccess(OutboxSuccess.entry)
            case .updateEntry(let entryId, let body):
                return try await updateEntry(id: entryId, body, options: options).mapSuccess(OutboxSuccess.entry)
            case .deleteEntry(let entryId):
                return try await deleteEntry(id: entryId, options: options).mapSuccess { _ in .empty }
            case .archiveTopic(let topicId, let revision):
                return try await archiveTopic(ref: topicId, expectedRevision: revision, options: options)
                    .mapSuccess(OutboxSuccess.topic)
            case .unarchiveTopic(let topicId, let revision):
                return try await unarchiveTopic(ref: topicId, expectedRevision: revision, options: options)
                    .mapSuccess(OutboxSuccess.topic)
            case .recordRunEvent(let runId, let body):
                return try await recordRunEvent(runId: runId, body, options: options)
                    .mapSuccess(OutboxSuccess.runEvent)
            case .getEntry(let entryId):
                return try await getEntry(id: entryId, options: options).mapSuccess(OutboxSuccess.entry)
            case .getTopic(let topicId):
                return try await getTopic(ref: topicId, options: options).mapSuccess(OutboxSuccess.topic)
            case .getRun(let runId):
                return try await getRun(id: runId, options: options).mapSuccess(OutboxSuccess.run)
            }
        } catch let error as APIClientError {
            return .refused(error, expecting: request.expecting)
        } catch {
            return .refused(.providerFailed(String(describing: error)), expecting: request.expecting)
        }
    }
}

extension APIResponse {
    /// The same response with the success value transformed.
    func mapSuccess<Other: Sendable>(_ transform: (Success) -> Other) -> APIResponse<Other> {
        APIResponse<Other>(
            outcome: outcome.map(transform), status: status, observed: observed, expected: expected, body: body,
            bodyIsTrusted: bodyIsTrusted)
    }
}

extension APIResponse where Success == OutboxSuccess {
    /// A request the client refused to build. Nothing was sent. A body that can't be encoded never
    /// will be (terminal, like the PWA's "Invalid item"); a provider failure may pass (retry).
    static func refused(_ error: APIClientError, expecting: ServerIdentity) -> Self {
        let outcome: APIOutcome<OutboxSuccess> =
            switch error {
            case .encodingFailed: .terminal(status: 0, problem: nil)
            case .noServerIdentity, .providerFailed: .retryable(.noResponse(.unreachable(error.description)))
            }
        return APIResponse(
            outcome: outcome, status: nil, observed: ObservedIdentity(serverId: nil, epoch: nil), expected: expecting,
            bodyIsTrusted: false)
    }

    /// `last_error_json` for this response. A refused request has no status, so the message is
    /// the client's reason.
    var outboxError: OutboxErrorInfo? {
        if case .terminal(status: 0, _) = outcome, status == nil {
            return OutboxErrorInfo(message: "Invalid item", status: nil)
        }
        return errorInfo
    }
}
