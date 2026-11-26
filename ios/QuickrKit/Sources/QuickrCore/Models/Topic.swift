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
    /// reads it from the current version's row, so it's nil there until that row is synced.
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

/// A version's timing (the server's `Timer`, timers.md §2.1, timers2.md §1.1): its named steps,
/// timed in this order, its lap types (laps cycle through them: "Run 1, Rest 1, Run 2"), and the
/// variables its alerts' expressions read. No steps is a plain stopwatch; no lap types, laps
/// labelled "Lap n" (v1). The wire shape, so it is `Codable` as is.
///
/// Decoding accepts the v1 shape `{steps: [{key, label}]}` (older servers, and the store's stored
/// `timer_json`): missing `laps`, `variables` and `alerts` default to `[]`, and a missing `at_ms`
/// to nil (a draft's alert; the server fills it, §1.1).
///
/// Encoding always writes `laps`, `variables` and each `alerts` (the normalised shape of §1.4),
/// so what a client sends is what the server serves back.
public struct TopicTimer: Codable, Sendable, Hashable {
    public var steps: [Step]
    public var laps: [LapType]
    public var variables: [Variable]

    public init(steps: [Step], laps: [LapType] = [], variables: [Variable] = []) {
        self.steps = steps
        self.laps = laps
        self.variables = variables
    }

    enum CodingKeys: String, CodingKey { case steps, laps, variables }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decode([Step].self, forKey: .steps)
        laps = try c.decodeIfPresent([LapType].self, forKey: .laps) ?? []
        variables = try c.decodeIfPresent([Variable].self, forKey: .variables) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        try c.encode(laps, forKey: .laps)
        try c.encode(variables, forKey: .variables)
    }

    /// The step or lap type keyed `key` (one namespace per timer, §1.1): its alerts.
    public func alerts(step: String?, lapType: String?) -> [Alert] {
        if let step { return steps.first { $0.key == step }?.alerts ?? [] }
        if let lapType { return laps.first { $0.key == lapType }?.alerts ?? [] }
        return []
    }

    /// A named checkpoint. Its key is its identity across versions (a step keeps it when renamed).
    public struct Step: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var alerts: [Alert]

        public init(key: String, label: String, alerts: [Alert] = []) {
            self.key = key
            self.label = label
            self.alerts = alerts
        }

        enum CodingKeys: String, CodingKey { case key, label, alerts }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            alerts = try c.decodeIfPresent([Alert].self, forKey: .alerts) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(label, forKey: .label)
            try c.encode(alerts, forKey: .alerts)
        }
    }

    /// A named kind of lap (§1.1): its key is the identity of its laps across versions.
    public struct LapType: Codable, Sendable, Hashable {
        public var key: String
        /// 1..64 characters (`ShortLabel`).
        public var label: String
        public var alerts: [Alert]

        public init(key: String, label: String, alerts: [Alert] = []) {
            self.key = key
            self.label = label
            self.alerts = alerts
        }

        enum CodingKeys: String, CodingKey { case key, label, alerts }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            alerts = try c.decodeIfPresent([Alert].self, forKey: .alerts) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(label, forKey: .label)
            try c.encode(alerts, forKey: .alerts)
        }
    }

    /// A named duration alert expressions read (`t`, `rest`); stored lowercase.
    public struct Variable: Codable, Sendable, Hashable {
        public var name: String
        public var ms: Int

        public init(name: String, ms: Int) {
            self.name = name
            self.ms = ms
        }
    }

    /// A cue that fires when the segment's active time reaches `atMs`, the server's evaluation of
    /// `at` (an expression, §2) over the timer's variables.
    public struct Alert: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var at: String
        /// Output only: nil on a draft the server hasn't evaluated.
        public var atMs: Int?

        public init(key: String, label: String, at: String, atMs: Int? = nil) {
            self.key = key
            self.label = label
            self.at = at
            self.atMs = atMs
        }

        enum CodingKeys: String, CodingKey {
            case key, label, at
            case atMs = "at_ms"
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
