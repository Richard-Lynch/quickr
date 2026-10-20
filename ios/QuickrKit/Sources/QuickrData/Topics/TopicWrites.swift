import Foundation
import GRDB
import QuickrCore

/// The online-only topic writes (sync-protocol.md §11): create, details and schedule edits
/// (`updateTopic`), and delete. They are never queued.
///
/// - **Fail closed.** A write belongs to the store bound when it starts (its ``Scope``): without
///   that store's identity nothing is sent, and the request carries the Expect headers, so another
///   server, or the same one after an epoch change, can never act on it.
/// - **Success.** The server executed it. The response's topic row (for a delete, the local
///   tombstone and its outbox cascade) is applied **fenced** on the request context in one
///   transaction (§5.5); if the fence fails (a swap or reset meanwhile) nothing local is written
///   and the pull brings the result. A pull is requested either way (`afterOnlineOnly`).
/// - **Mismatch.** A 409 `server_mismatch`/`epoch_mismatch`, or headers from another server or
///   epoch: "quickR is resyncing" and a coordinator run (§5.6).
public struct TopicWrites: Sendable {
    /// What a write needs from the bound store, captured before it is sent.
    public struct Scope: Sendable, Hashable {
        public var binding: AppSession.Binding
        public var context: RequestContext
        public var identity: ServerIdentity

        public init(binding: AppSession.Binding, context: RequestContext, identity: ServerIdentity) {
            self.binding = binding
            self.context = context
            self.identity = identity
        }
    }

    /// What became of a write, for the screen.
    public enum Outcome<Value: Sendable>: Sendable {
        /// The server executed it.
        case done(Value)
        /// No connection: nothing reached the server. "Needs a connection".
        case offline
        /// No identity for the bound store yet (it hasn't synced), or it couldn't be read: nothing
        /// was sent.
        case notReady
        /// Another server or epoch answered, or refused the preconditions: "quickR is resyncing".
        case resyncing
        /// The server refused it (422 validation, 409 slug taken or not archived, 400…), with its
        /// Problem when it sent one from the expected server.
        case rejected(status: Int, problem: Problem?)
        /// `expected_revision` no longer matches: someone else changed the topic.
        case staleRevision(Problem)
        /// The topic isn't on the server any more.
        case notFound
        /// It may or may not have executed (a timeout after sending, a 5xx, an unreadable 2xx): a
        /// pull is requested so the screen can show what happened.
        case unconfirmed(String)
        /// Refused for a reason retrying might fix (401/403/429, a redirect, an odd status).
        case failed(String)
    }

    public static let offlineMessage = "Needs a connection. Connect to the internet, then try again."
    public static let notReadyMessage = "This server hasn’t finished syncing yet. Try again in a moment."
    public static let resyncingMessage = "quickR is resyncing, try again in a moment."
    public static let unconfirmedMessage =
        "The connection dropped before the server answered. Check the topic once it has synced."

    public let scope: Scope
    let store: LocalStore
    let client: APIClient
    let requestSync: @Sendable (SyncReason) async -> Void

    /// `requestSync` asks the coordinator for a run (`afterOnlineOnly` after a success or an
    /// unconfirmed write; `requested` after a mismatch).
    public init(
        scope: Scope, store: LocalStore, transport: any Transport, credentials: any AccessCredentialsProvider,
        requestSync: @escaping @Sendable (SyncReason) async -> Void
    ) {
        self.scope = scope
        self.store = store
        self.requestSync = requestSync
        client = APIClient(
            baseURL: scope.binding.baseURL, transport: transport, identity: StaticServerIdentity(scope.identity),
            credentials: credentials, origin: .app)
    }

    /// The scope of a write starting now: the binding, its store's request context and identity.
    /// Nil, so nothing is sent, when there is no binding, `store` isn't the bound one, or its
    /// context can't be read or has no epoch yet.
    public static func scope(binding: AppSession.Binding?, store: LocalStore?) async -> Scope? {
        guard let binding, let store, store.serverId == binding.serverId, store.storeGen == binding.storeGen,
            let context = try? await store.requestContext(), context.serverId == binding.serverId,
            context.storeGen == binding.storeGen, let identity = context.identity
        else { return nil }
        return Scope(binding: binding, context: context, identity: identity)
    }

    // MARK: Writes

    /// `POST /topics`. On success the new topic is in the store (fence permitting).
    public func create(_ body: TopicCreateDTO) async -> Outcome<Topic> {
        await send(
            { try await client.createTopic(body, options: options).outcome },
            apply: { db, topic in _ = try ServerLayer.upsert(db, topic: topic) })
    }

    /// `PATCH /topics/{ref}`: details and schedule (`ref` is the topic's id; ids never change).
    public func update(topicId: UUID, _ body: TopicUpdateDTO) async -> Outcome<Topic> {
        await send(
            { try await client.updateTopic(ref: topicId.wireString, body, options: options).outcome },
            apply: { db, topic in _ = try ServerLayer.upsert(db, topic: topic) })
    }

    /// `DELETE /topics/{ref}` (only an archived topic; the server refuses others with a 409). On
    /// success the topic, its versions and entries are tombstoned locally, and its outbox items
    /// resolve as for a deletion that arrived in the feed (§4.3).
    public func delete(topicId: UUID) async -> Outcome<Void> {
        let wall = store.wallClock
        let id = topicId
        return await send(
            { try await client.deleteTopic(ref: id.wireString, options: options).outcome.map { _ in () } },
            apply: { db, _ in
                try ServerLayer.applyDeletion(db, kind: .topic, id: id, topicId: id, seq: nil)
                try OutboxSyncEffects.resolveDependents(db, kind: .topic, id: id.wireString, wall: wall.now())
            })
    }

    private var options: RequestOptions { RequestOptions(expecting: scope.identity) }

    /// Sends, classifies, and on success applies `apply` fenced on the scope's context.
    private func send<Value: Sendable>(
        _ request: @Sendable () async throws -> APIOutcome<Value>,
        apply: @escaping @Sendable (Database, Value) throws -> Void
    ) async -> Outcome<Value> {
        let outcome: APIOutcome<Value>
        do {
            outcome = try await request()
        } catch {
            // The client refused to send (no identity, an unencodable body, a provider failure).
            return .failed(String(describing: error))
        }
        switch outcome {
        case .success(let value):
            // A failed fence (swap or reset meanwhile) writes nothing; the pull brings it instead.
            _ = try? await store.applyFenced(scope.context) { db in try apply(db, value) }
            await requestSync(.afterOnlineOnly)
            return .done(value)
        case .retryable(.noResponse):
            return .offline
        case .uncertain(let reason):
            await requestSync(.afterOnlineOnly)
            if case .serverError(_, let problem?) = reason, !problem.detail.isEmpty {
                return .unconfirmed(problem.detail)
            }
            return .unconfirmed(Self.unconfirmedMessage)
        case .identityMismatch, .epochMismatch:
            await requestSync(.requested)
            return .resyncing
        case .terminal(let status, let problem):
            return .rejected(status: status, problem: problem)
        case .staleRevision(let problem):
            return .staleRevision(problem)
        case .notFound:
            return .notFound
        case .entryDeleted(let problem):
            return .rejected(status: 409, problem: problem)
        case .retryable(.status(let status, let problem)):
            return .failed(problem?.detail ?? Self.statusMessage(status))
        case .retryable(.redirect(let status)), .retryable(.unexpectedResponse(let status)):
            return .failed(Self.statusMessage(status))
        }
    }

    static func statusMessage(_ status: Int) -> String {
        switch status {
        case 401, 403: "The server refused access (HTTP \(status)). Check the server’s access settings."
        case 429: "The server is busy. Try again in a moment."
        default: "The server couldn’t do that (HTTP \(status))."
        }
    }

    // MARK: Before a delete

    /// How many queued or failed changes the topic has: they are lost when it is deleted
    /// ("_N_ unsynced changes for this topic will be lost", §11).
    public static func unsyncedChanges(topicId: UUID, in store: LocalStore) async throws -> Int {
        try await store.outbox.items(topicId: topicId.wireString).count
    }

    public static func unsyncedChangesWarning(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 unsynced change for this topic will be lost."
        default: "\(count) unsynced changes for this topic will be lost."
        }
    }
}
