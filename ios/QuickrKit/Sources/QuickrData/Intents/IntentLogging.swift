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
    /// Keeps this process's databases writable while an intent's write runs, returning the
    /// release: the app's is `AppSession.holdStoreResumed` (Siri or a widget button can act while
    /// the app is suspended in the background, its GRDB suspended); an extension never suspends.
    public var holdStore: @Sendable () async -> @Sendable () async -> Void

    public init(
        origin: OutboxOrigin, openActiveStore: @escaping @Sendable () async throws -> LocalStore?,
        afterCommit: @escaping @Sendable (LocalStore) async -> Void = { _ in },
        wallClock: any WallClock = SystemWallClock(),
        holdStore: @escaping @Sendable () async -> @Sendable () async -> Void = { {} }
    ) {
        self.origin = origin
        self.openActiveStore = openActiveStore
        self.afterCommit = afterCommit
        self.wallClock = wallClock
        self.holdStore = holdStore
    }
}

/// Where this process's `IntentWriteContext` is registered.
public enum IntentWrites {
    private static let current = Mutex<IntentWriteContext?>(nil)

    public static func register(_ context: IntentWriteContext) {
        current.withLock { $0 = context }
    }

    public static func context() -> IntentWriteContext? { current.withLock { $0 } }
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
    public struct Logged: Sendable {
        public var entryId: UUID
        public var topic: Topic
        public var answers: [String: AnswerValue]
        /// False when a slot-bound log found the slot already logged (nothing was written).
        public var created: Bool
        /// The store the entry was committed to: undo goes there, whichever store is active by
        /// then (its fences refuse a store reset or retired since).
        public var store: LocalStore

        /// Which server and generation it went to.
        public var scope: EntryScope { store.scope }
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
    /// Runs `work` with the store held writable (`IntentWriteContext.holdStore`), released on
    /// every path.
    public static func holding<T>(_ context: IntentWriteContext, _ work: () async throws -> T) async throws -> T {
        let release = await context.holdStore()
        do {
            let value = try await work()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    public static func log(
        topicId: UUID, answers: [String: AnswerValue], slot: Slot? = nil, in context: IntentWriteContext
    ) async throws -> Logged {
        try await holding(context) { try await commit(topicId: topicId, answers: answers, slot: slot, in: context) }
    }

    private static func commit(
        topicId: UUID, answers: [String: AnswerValue], slot: Slot?, in context: IntentWriteContext
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
        return Logged(entryId: entryId, topic: topic, answers: validated, created: created, store: store)
    }

    /// Undo of an intent's log (`UndoableIntent`): `cancelCreate` (outbox.md §9.1) in the store the
    /// entry was committed to, never whichever store is active now (the user may have switched
    /// servers since). A create not sent yet is removed; one that may have been sent becomes a
    /// queued delete, which reserves the id. A store retired since (a reset) throws
    /// `storeUnavailable`: its file is gone, and the entry with it.
    @discardableResult
    public static func undo(_ logged: Logged, in context: IntentWriteContext) async throws -> OutboxUndoLogResult {
        try await holding(context) { try await cancel(logged, in: context) }
    }

    private static func cancel(_ logged: Logged, in context: IntentWriteContext) async throws -> OutboxUndoLogResult {
        let (store, entryId) = (logged.store, logged.entryId)
        let (clock, wall, origin) = (store.leaseClock, store.wallClock, context.origin)
        let result: OutboxUndoLogResult
        do {
            result = try await store.writer.write { db in
                try OutboxQueue.cancelCreate(
                    db, entryId: entryId.wireString, origin: origin, now: clock.now(), wall: wall.now())
            }
        } catch {
            throw Failure.storeUnavailable
        }
        if !Task.isCancelled { await context.afterCommit(store) }
        return result
    }

    /// What repeat-last does for a topic (PLAN §2 "Repeat-last").
    public enum RepeatPlan: Sendable, Hashable {
        /// The latest entry's answers still validate against the current version: log them.
        case log([String: AnswerValue])
        /// They don't (or there is no entry): open the record screen, prefilled with what still
        /// applies (nil when there is no entry).
        case openRecord(prefill: [String: AnswerValue]?)
    }

    /// The plan for repeating `topicId`'s latest counted entry (the view's, queued logs included).
    /// Answers to questions the current version no longer has are dropped first. An archived or
    /// missing topic throws, like a log.
    public static func repeatPlan(topicId: UUID, in context: IntentWriteContext) async throws -> (Topic, RepeatPlan) {
        let (store, topic) = try await self.topic(topicId, in: context)
        let latest = try? await store.writer.read { db in try StoreView.latestEntry(db, topicId: topicId.wireString) }
        guard let entry = latest ?? nil else { return (topic, .openRecord(prefill: nil)) }
        let keys = Set(topic.questions.map(\.key))
        let carried = entry.entry.answers.filter { keys.contains($0.key) }
        switch validate(carried, questions: topic.questions) {
        case .success(let answers): return (topic, .log(answers))
        case .failure: return (topic, .openRecord(prefill: carried))
        }
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
