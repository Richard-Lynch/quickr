import Foundation
import GRDB
import QuickrCore

/// The online-only topic writes (sync-protocol.md §11): create, details and schedule edits
/// (`updateTopic`), delete, and a new version (its check, the publish, and reloading the topic
/// after a conflict); and an entry's Edit times (timers.md §3.8). They are never queued.
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
        /// The outbox is sending (it holds the `flush` lease) and didn't finish in time: nothing was
        /// sent. "Sync is busy, try again".
        case busy
        /// It may or may not have executed (a timeout after sending, a 5xx, an unreadable 2xx): a
        /// pull is requested so the screen can show what happened.
        case unconfirmed(String)
        /// Refused for a reason retrying might fix (401/403/429, a redirect, an odd status).
        case failed(String)
    }

    /// A dry run (a version check) that got no answer.
    public static let noAnswerMessage = "The connection dropped before the server answered. Try again."

    /// The screens' other messages are QuickrUI's (`TopicWriteMessage`).
    public static let unconfirmedMessage =
        "The connection dropped before the server answered. Check the topic once it has synced."

    /// An editor whose base version hasn't synced yet: its timer, which the draft starts from
    /// and a publish must carry, isn't known.
    public static let baseVersionMissingMessage =
        "This topic’s latest version hasn’t synced yet. Try again in a moment."

    public let scope: Scope
    let store: LocalStore
    let client: APIClient
    let requestSync: @Sendable (SyncReason) async -> Void
    /// The `flush` lease owner a delete holds it as.
    let leaseOwner: String
    /// How long a delete waits for the `flush` lease before saying sync is busy.
    let leaseWait: Duration

    /// A delete holds `flush` for an archive and the DELETE: two requests of at most 15 s each.
    static let deleteLeaseTTL: Duration = .seconds(45)

    /// `requestSync` asks the coordinator for a run (`afterOnlineOnly` after a success or an
    /// unconfirmed write; `requested` after a mismatch).
    public init(
        scope: Scope, store: LocalStore, transport: any Transport, credentials: any AccessCredentialsProvider,
        leaseOwner: String = LeaseClaim.owner(kind: "topic-writes", launchId: UUID()),
        leaseWait: Duration = .seconds(10), requestSync: @escaping @Sendable (SyncReason) async -> Void
    ) {
        self.scope = scope
        self.store = store
        self.leaseOwner = leaseOwner
        self.leaseWait = leaseWait
        self.requestSync = requestSync
        client = APIClient(
            baseURL: scope.binding.baseURL, transport: transport, identity: StaticServerIdentity(scope.identity),
            credentials: credentials, origin: .app, serverOffset: StoreServerOffset(store: store))
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
    /// (entry changes, a queued archive or unarchive) resolve as for a deletion that arrived in the
    /// feed (§4.3), in the same fenced transaction.
    ///
    /// The whole sequence holds the outbox's `flush` lease, so no flush in any process sends one of
    /// the topic's queued items meanwhile (a queued unarchive can never land between the archive
    /// and the DELETE). An archive still queued (made offline, or held behind a failed change,
    /// which the outbox never sends past) means the server's copy may not be archived yet: it is
    /// sent first, online only like the delete. Nothing local changes unless the DELETE succeeds,
    /// so a failed delete loses nothing. The lease is released on every path, cancellation
    /// included; if it isn't free within `leaseWait`, nothing is sent (`busy`).
    public func delete(topicId: UUID) async -> Outcome<Void> {
        let leases = store.leases
        let claim: LeaseClaim?
        do {
            claim = try await leases.acquire(
                .flush, owner: leaseOwner, ttl: Self.deleteLeaseTTL, waitingUpTo: leaseWait)
        } catch {
            return .failed(String(describing: error))
        }
        guard let claim else { return .busy }
        let outcome = await delete(topicId: topicId, holding: claim)
        // In an unstructured task: the caller's cancellation can't stop the release.
        _ = try? await Task { try await leases.release(claim) }.value
        return outcome
    }

    private func delete(topicId: UUID, holding claim: LeaseClaim) async -> Outcome<Void> {
        let queued: [OutboxItem]
        do {
            queued = try await Self.pendingArchives(topicId: topicId, in: store)
        } catch {
            return .failed(String(describing: error))
        }
        if queued.last?.kind == .topicArchive {
            switch await archive(topicId: topicId) {
            case .done: break
            case let other: return other.withoutValue
            }
            // A fresh lease time for the DELETE; a lost lease (it expired) stops here.
            guard (try? await store.leases.renew(claim, ttl: Self.deleteLeaseTTL)) == true else { return .busy }
        }
        let wall = store.wallClock
        let id = topicId
        return await send(
            { try await client.deleteTopic(ref: id.wireString, options: options).outcome.map { _ in () } },
            apply: { db, _ in
                // This device's delete supersedes the topic's queued archive and unarchive (K3-style:
                // nothing of them is left to show); its entry changes then resolve by §4.3.
                for item in try OutboxStorage.items(db, topicId: id.wireString)
                where item.kind.isTopicKind && item.state != .inFlight {
                    _ = try OutboxStorage.delete(db, id: item.id)
                }
                try ServerLayer.applyDeletion(db, kind: .topic, id: id, topicId: id, seq: nil)
                try OutboxSyncEffects.resolveDependents(db, kind: .topic, id: id.wireString, wall: wall.now())
            })
    }

    /// `POST /topics/{ref}/versions/check`: a dry run of a new version against `body`'s base (409
    /// `conflict` when the topic has a newer version). Nothing local changes and no pull follows.
    public func checkVersion(topicId: UUID, _ body: VersionDraftDTO) async -> Outcome<CompatibilityReport> {
        await send({ try await client.checkTopicVersion(ref: topicId.wireString, body, options: options).outcome })
    }

    /// Publishes `version` (``TopicRequests/publish(_:baseVersion:changeNote:)``), with the
    /// draft's timer: a publish must send one (null turns timing off, timers.md §2.1).
    public func publishVersion(
        topicId: UUID, _ version: TopicDraft.Version, baseVersion: Int, changeNote: String
    ) async -> Outcome<Topic> {
        await publishVersion(
            topicId: topicId, TopicRequests.publish(version, baseVersion: baseVersion, changeNote: changeNote))
    }

    /// `POST /topics/{ref}/versions`: publishes the next version (409 `conflict` on a stale
    /// `base_version`, seen live). On success the topic row, with the new current version and its
    /// questions, is in the store (fence permitting); the version's own row comes with the pull.
    public func publishVersion(topicId: UUID, _ body: VersionCreateDTO) async -> Outcome<Topic> {
        await send(
            { try await client.publishTopicVersion(ref: topicId.wireString, body, options: options).outcome },
            apply: { db, topic in _ = try ServerLayer.upsert(db, topic: topic) })
    }

    /// `GET /topics/{ref}`: the server's topic now (an editor's "Load latest version" after a
    /// conflict). It is applied like a write's response, and a pull brings its new versions.
    public func latest(topicId: UUID) async -> Outcome<Topic> {
        await send(
            { try await client.getTopic(ref: topicId.wireString, options: options).outcome },
            apply: { db, topic in _ = try ServerLayer.upsert(db, topic: topic) })
    }

    // MARK: Edit times

    /// `PATCH /entries/{id}` with `timing` (Edit times, timers.md §3.8), online only, unlike the
    /// entry's other edits: the outbox rebases a `stale_revision` and resends (outbox.md §7.4),
    /// which would save times edited from an older revision over newer ones. Here the 409 comes
    /// back to the form (`staleRevision`), which asks for a reload instead. `captured_at` is never
    /// sent with it (the server derives it, T1). On success the entry is in the store (fence
    /// permitting) and a pull follows.
    public func updateEntryTiming(entryId: UUID, _ edit: TimingDraft.Edit, expectedRevision: Int) async
        -> Outcome<Entry>
    {
        let body = EntryUpdateDTO(timing: TimingEditDTO(edit), expectedRevision: expectedRevision)
        return await send(
            { try await client.updateEntry(id: entryId, body, options: options).outcome },
            apply: { db, entry in _ = try ServerLayer.upsert(db, entry: entry) })
    }

    /// `GET /entries/{id}`: the entry as the server holds it now (Edit times' "Reload times"),
    /// applied like a write's response.
    public func latestEntry(entryId: UUID) async -> Outcome<Entry> {
        await send(
            { try await client.getEntry(id: entryId, options: options).outcome },
            apply: { db, entry in _ = try ServerLayer.upsert(db, entry: entry) })
    }

    /// `GET /topics/{ref}/versions`: every version, for the step keys they have used (the editor's
    /// history after "Load latest version"). A read: nothing is applied; the pull brings the rows.
    public func versions(topicId: UUID) async -> Outcome<[TopicVersion]> {
        await send({ try await client.listTopicVersions(ref: topicId.wireString, options: options).outcome })
    }

    /// `POST /topics/{ref}/archive` sent now, for a delete (see ``delete(topicId:)``).
    func archive(topicId: UUID) async -> Outcome<Topic> {
        await send(
            { try await client.archiveTopic(ref: topicId.wireString, options: options).outcome },
            apply: { db, topic in _ = try ServerLayer.upsert(db, topic: topic) })
    }

    private var options: RequestOptions { RequestOptions(expecting: scope.identity) }

    /// Sends a dry run: nothing to apply and nothing to pull. A response that never came back
    /// changed nothing either, so it is a plain failure.
    private func send<Value: Sendable>(_ request: @Sendable () async throws -> APIOutcome<Value>) async
        -> Outcome<Value>
    {
        switch await send(request, apply: nil) {
        case .unconfirmed(let message): .failed(message == Self.unconfirmedMessage ? Self.noAnswerMessage : message)
        case let other: other
        }
    }

    /// Sends, classifies, and on success applies `apply` fenced on the scope's context, then asks
    /// for a pull. Without `apply` (a dry run) a success only returns the value.
    private func send<Value: Sendable>(
        _ request: @Sendable () async throws -> APIOutcome<Value>,
        apply: (@Sendable (Database, Value) throws -> Void)?
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
            guard let apply else { return .done(value) }
            // A failed fence (swap or reset meanwhile) writes nothing; the pull brings it instead.
            _ = try? await store.applyFenced(scope.context) { db in try apply(db, value) }
            await requestSync(.afterOnlineOnly)
            return .done(value)
        case .retryable(.noResponse):
            return .offline
        case .uncertain(let reason):
            if apply != nil { await requestSync(.afterOnlineOnly) }
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

    /// How many queued or failed entry changes the topic has: they are lost when it is deleted
    /// ("_N_ unsynced changes for this topic will be lost", §11). A queued archive or unarchive
    /// isn't one: deleting supersedes it (the delete sends it first, ``pendingArchives``).
    public static func unsyncedChanges(topicId: UUID, in store: LocalStore) async throws -> Int {
        try await store.outbox.items(topicId: topicId.wireString).count { !$0.kind.isTopicKind }
    }

    /// The topic's queued (not failed) archive and unarchive items: a delete sends them first, as
    /// the server deletes only an archived topic.
    public static func pendingArchives(topicId: UUID, in store: LocalStore) async throws -> [OutboxItem] {
        try await store.outbox.items(topicId: topicId.wireString).filter { $0.kind.isTopicKind && $0.state != .failed }
    }
}

extension OutboxKind {
    /// `topic.archive` or `topic.unarchive`.
    var isTopicKind: Bool { self == .topicArchive || self == .topicUnarchive }
}

extension TopicWrites.Outcome {
    /// The same failure for a write without a value (`done` keeps its kind, with `()`).
    var withoutValue: TopicWrites.Outcome<Void> {
        switch self {
        case .done: .done(())
        case .offline: .offline
        case .notReady: .notReady
        case .resyncing: .resyncing
        case .rejected(let status, let problem): .rejected(status: status, problem: problem)
        case .staleRevision(let problem): .staleRevision(problem)
        case .notFound: .notFound
        case .busy: .busy
        case .unconfirmed(let message): .unconfirmed(message)
        case .failed(let message): .failed(message)
        }
    }
}
