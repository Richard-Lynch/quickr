import Foundation

/// A topic with its current questions (the server's `TopicDetail`).
///
/// `entryCount`, `lastCapturedAt` and `due` are derived fields. The server's values are carried
/// here as reported; the store recomputes them from its view and never trusts these
/// (sync-protocol.md §3.3).
public struct Topic: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var slug: String
    public var name: String
    public var description: String
    public var status: TopicStatus
    public var currentVersion: Int
    /// Starts at 1 and increases with every change to the topic's own fields (F4).
    public var revision: Int
    public var questionCount: Int
    public var entryCount: Int
    public var lastCapturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var schedule: Schedule?
    public var scheduleUpdatedAt: Date?
    public var due: DueStatus?
    /// The current version's timer; nil when the topic isn't timed (timers.md §2.1). The store
    /// doesn't keep it on the topic row yet, so a topic read from the store has nil here; the
    /// current `TopicVersion` there has it.
    public var timer: TopicTimer?
    public var questions: [Question]

    public init(
        id: UUID, slug: String, name: String, description: String = "", status: TopicStatus = .active,
        currentVersion: Int, revision: Int, questionCount: Int, entryCount: Int = 0, lastCapturedAt: Date? = nil,
        createdAt: Date, updatedAt: Date, archivedAt: Date? = nil, schedule: Schedule? = nil,
        scheduleUpdatedAt: Date? = nil, due: DueStatus? = nil, timer: TopicTimer? = nil, questions: [Question]
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.status = status
        self.currentVersion = currentVersion
        self.revision = revision
        self.questionCount = questionCount
        self.entryCount = entryCount
        self.lastCapturedAt = lastCapturedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.schedule = schedule
        self.scheduleUpdatedAt = scheduleUpdatedAt
        self.due = due
        self.timer = timer
        self.questions = questions
    }
}

/// A topic without its questions (the server's `TopicSummary`, from `listTopics`).
public struct TopicSummary: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var slug: String
    public var name: String
    public var description: String
    public var status: TopicStatus
    public var currentVersion: Int
    public var revision: Int
    public var questionCount: Int
    public var entryCount: Int
    public var lastCapturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var schedule: Schedule?
    public var scheduleUpdatedAt: Date?
    public var due: DueStatus?
    /// The current version's timer; nil when the topic isn't timed (timers.md §2.1).
    public var timer: TopicTimer?

    public init(
        id: UUID, slug: String, name: String, description: String, status: TopicStatus, currentVersion: Int,
        revision: Int, questionCount: Int, entryCount: Int, lastCapturedAt: Date?, createdAt: Date,
        updatedAt: Date, archivedAt: Date?, schedule: Schedule?, scheduleUpdatedAt: Date?, due: DueStatus?,
        timer: TopicTimer?
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.status = status
        self.currentVersion = currentVersion
        self.revision = revision
        self.questionCount = questionCount
        self.entryCount = entryCount
        self.lastCapturedAt = lastCapturedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.schedule = schedule
        self.scheduleUpdatedAt = scheduleUpdatedAt
        self.due = due
        self.timer = timer
    }
}

/// One immutable version of a topic's question set (the server's `TopicVersionOut`).
///
/// The version's own id and its topic id are not part of this payload; the change feed carries
/// them next to it (`ChangeItem.version`), and the store keys rows by them.
public struct TopicVersion: Sendable, Hashable {
    public var version: Int
    public var questions: [Question]
    /// Nil when the version isn't timed. A topic is timed when its current version has one.
    public var timer: TopicTimer?
    public var changeNote: String
    public var createdAt: Date
    /// Derived; recomputed locally (sync-protocol.md §3.3).
    public var entryCount: Int

    public init(
        version: Int, questions: [Question], timer: TopicTimer? = nil, changeNote: String = "", createdAt: Date,
        entryCount: Int = 0
    ) {
        self.version = version
        self.questions = questions
        self.timer = timer
        self.changeNote = changeNote
        self.createdAt = createdAt
        self.entryCount = entryCount
    }
}

/// A version's timing (the server's `Timer`, timers.md §2.1): its named steps, timed in this
/// order. No steps is a plain stopwatch. The wire shape, so it is `Codable` as is.
public struct TopicTimer: Codable, Sendable, Hashable {
    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// A named checkpoint. Its key is its identity across versions (a step keeps it when renamed).
    public struct Step: Codable, Sendable, Hashable {
        public var key: String
        public var label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }
}

/// One page of an offset-paginated list (`TopicPage`, `EntryPage`).
public struct Page<Item: Sendable & Hashable>: Sendable, Hashable {
    public var items: [Item]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(items: [Item], total: Int, limit: Int, offset: Int) {
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}
