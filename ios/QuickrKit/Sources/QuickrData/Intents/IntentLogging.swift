import Foundation
import QuickrCore
import Synchronization

/// How this process writes from App Intents (research/04-siri.md §5): the app registers its own at
/// launch (origin `.siri`), the widget extension its own (`.widget`). Like `IntentTopicSource`,
/// not `@Dependency`, so widget buttons and tests reach it outside the system's intent flow.
public struct IntentWriteContext: Sendable {
    /// `.siri` in the app (Siri, Shortcuts, the Action button), `.widget` in the widget extension.
    public var origin: OutboxOrigin
    /// The active store, writable; nil when there is none yet or it can't be opened (before first
    /// unlock, a reset in progress).
    public var openActiveStore: @Sendable () async throws -> LocalStore?
    /// After a commit: ask for a flush (the app's scheduler; the extension's bounded flush). Best
    /// effort and cancellation-aware: the entry is already durable (spike S3: 30 s, then cancel).
    public var afterCommit: @Sendable (LocalStore) async -> Void
    public var wallClock: any WallClock

    public init(
        origin: OutboxOrigin, openActiveStore: @escaping @Sendable () async throws -> LocalStore?,
        afterCommit: @escaping @Sendable (LocalStore) async -> Void = { _ in },
        wallClock: any WallClock = SystemWallClock()
    ) {
        self.origin = origin
        self.openActiveStore = openActiveStore
        self.afterCommit = afterCommit
        self.wallClock = wallClock
    }
}

/// Where this process's `IntentWriteContext` is registered.
public enum IntentWrites {
    private static let current = Mutex<IntentWriteContext?>(nil)

    public static func register(_ context: IntentWriteContext) {
        current.withLock { $0 = context }
    }

    static func context() -> IntentWriteContext? { current.withLock { $0 } }
}

/// The one commit every logging intent goes through (`LogEntryIntent`, `LogTopicIntent`,
/// `RepeatLastEntryIntent`): checked against the **active** store (a topic from another server,
/// or one deleted or archived, is refused), validated against the topic's current version, then
/// one durable `entry.create`. The entry id is the shared action entry id (notifications.md §7.4)
/// only when the log is bound to a reminder slot (`dueSince`); otherwise a random one, so
/// logging a topic twice on purpose logs twice.
public enum IntentLogging {
    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        /// No server yet, or the store can't be opened now.
        case noStore
        /// Not in the active store: deleted, or from another server.
        case topicNotFound
        case topicArchived
        /// A slot-bound log for a server that isn't the active one.
        case otherServer
        /// The answers don't validate: the first message.
        case invalid(String)
        /// The store couldn't be written.
        case storeUnavailable

        public var description: String {
            switch self {
            case .noStore: "quickR isn't set up yet: open it to connect to your server."
            case .topicNotFound: "That topic isn't on your current quickR server."
            case .topicArchived: "That topic is archived."
            case .otherServer: "That reminder is from another quickR server."
            case .invalid(let message): message
            case .storeUnavailable: "quickR couldn't save the entry. Open quickR to log it."
            }
        }
    }

    /// What a commit did.
    public struct Logged: Sendable, Hashable {
        public var entryId: UUID
        public var topic: Topic
        public var answers: [String: AnswerValue]
        /// False when a slot-bound log found the slot already logged (nothing was written).
        public var created: Bool
    }

    /// The reminder slot a log is bound to: it uses the shared action entry id.
    public struct Slot: Sendable, Hashable {
        public var serverId: String
        /// Canonical `due_since`, exactly as the reminder carries it.
        public var dueSince: String

        public init(serverId: String, dueSince: String) {
            self.serverId = serverId
            self.dueSince = dueSince
        }
    }

    /// The active store's view of `topicId`, for an intent to ask its questions against.
    public static func topic(_ topicId: UUID, in context: IntentWriteContext) async throws -> (LocalStore, Topic) {
        guard let store = try? await context.openActiveStore() else { throw Failure.noStore }
        let view = try? await store.writer.read { db in
            (
                try StoreView.topic(db, id: topicId.wireString),
                try ServerLayer.isTombstoned(db, kind: .topic, id: topicId.wireString)
            )
        }
        guard let (topic, tombstoned) = view, !tombstoned, let topic else { throw Failure.topicNotFound }
        guard topic.topic.status == .active else { throw Failure.topicArchived }
        return (store, topic.topic)
    }

    /// Validates `answers` against the topic's current version (required questions answered,
    /// each answer valid for its question) and logs them, durably, before returning.
    public static func log(
        topicId: UUID, answers: [String: AnswerValue], slot: Slot? = nil, in context: IntentWriteContext
    ) async throws -> Logged {
        let (store, topic) = try await self.topic(topicId, in: context)
        if let slot, slot.serverId.lowercased() != store.serverId.lowercased() { throw Failure.otherServer }
        let validated: [String: AnswerValue]
        switch validate(answers, questions: topic.questions) {
        case .success(let answers): validated = answers
        case .failure(let failure): throw failure
        }
        let entryId =
            slot.map { ActionEntryId.make(serverId: $0.serverId, topicId: topicId.wireString, dueSince: $0.dueSince) }
            ?? UUID()
        let body = EntryCreateDTO(
            id: nil, answers: validated, source: nil, capturedAt: context.wallClock.now(), notes: "", meta: [:],
            version: topic.currentVersion)
        let ref = TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
        let result: OutboxCreateOnceResult
        do {
            result = try await store.createEntryIfAbsent(id: entryId, topic: ref, body: body, origin: context.origin)
        } catch {
            throw Failure.storeUnavailable
        }
        let created = if case .created = result { true } else { false }
        if !Task.isCancelled { await context.afterCommit(store) }
        return Logged(entryId: entryId, topic: topic, answers: validated, created: created)
    }

    /// `answers` checked like the record form (`AnswerValidator`): every answer belongs to a
    /// question and validates for it, every required question is answered. The validated
    /// (normalised) answers, or the first problem.
    static func validate(_ answers: [String: AnswerValue], questions: [Question]) -> Result<
        [String: AnswerValue], Failure
    > {
        let keys = Set(questions.map(\.key))
        if let stray = answers.keys.sorted().first(where: { !keys.contains($0) }) {
            return .failure(.invalid("\(stray) isn't a question of this topic."))
        }
        let inputs = Dictionary(
            uniqueKeysWithValues: questions.map { ($0.key, AnswerInput(answers[$0.key], for: $0)) })
        switch AnswerValidator(questions: questions).validate(inputs) {
        case .success(let validated):
            return .success(validated.answered)
        case .failure(let errors):
            let first = errors.first
            let label = questions.first { $0.key == first?.key }?.label ?? first?.key ?? ""
            return .failure(.invalid("\(label): \(first?.message ?? "invalid")"))
        }
    }
}
