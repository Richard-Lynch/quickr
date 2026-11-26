import Foundation
import QuickrCore

public struct DueStatusDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var isDue: Bool
    @RequiredKey public var dueSince: Date?
    @RequiredKey public var nextDueAt: Date?
    @RequiredKey public var lastEntryAt: Date?

    enum CodingKeys: String, CodingKey {
        case isDue = "is_due"
        case dueSince = "due_since"
        case nextDueAt = "next_due_at"
        case lastEntryAt = "last_entry_at"
    }

    public func toDomain() -> DueStatus {
        DueStatus(isDue: isDue, dueSince: dueSince, nextDueAt: nextDueAt, lastEntryAt: lastEntryAt)
    }
}

/// `Timer` as the server returns it (timers2.md §1.4): normalised, so every key is required on
/// the wire (`TopicTimer`'s own decoding is lenient for v1-shaped stored JSON). Maps one to one
/// onto the v2 `TopicTimer`: steps, lap types, variables and alerts all reach the domain.
public struct TopicTimerDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var steps: [StepDTO]
    public var laps: [LapTypeDTO]
    public var variables: [VariableDTO]

    public struct StepDTO: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var alerts: [AlertDTO]
    }

    public struct LapTypeDTO: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var alerts: [AlertDTO]
    }

    public struct VariableDTO: Codable, Sendable, Hashable {
        public var name: String
        public var ms: Int
    }

    public struct AlertDTO: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var at: String
        public var atMs: Int

        enum CodingKeys: String, CodingKey {
            case key, label, at
            case atMs = "at_ms"
        }

        init(_ alert: TopicTimer.Alert) {
            key = alert.key
            label = alert.label
            at = alert.at
            atMs = alert.atMs ?? 0
        }

        var domain: TopicTimer.Alert { TopicTimer.Alert(key: key, label: label, at: at, atMs: atMs) }
    }

    /// The server's normalised form of `timer` (a draft alert's missing `at_ms` reads 0; the
    /// test servers that use this don't evaluate expressions).
    public init(_ timer: TopicTimer) {
        steps = timer.steps.map { StepDTO(key: $0.key, label: $0.label, alerts: $0.alerts.map(AlertDTO.init)) }
        laps = timer.laps.map { LapTypeDTO(key: $0.key, label: $0.label, alerts: $0.alerts.map(AlertDTO.init)) }
        variables = timer.variables.map { VariableDTO(name: $0.name, ms: $0.ms) }
    }

    public func toDomain() -> TopicTimer {
        TopicTimer(
            steps: steps.map { TopicTimer.Step(key: $0.key, label: $0.label, alerts: $0.alerts.map(\.domain)) },
            laps: laps.map { TopicTimer.LapType(key: $0.key, label: $0.label, alerts: $0.alerts.map(\.domain)) },
            variables: variables.map { TopicTimer.Variable(name: $0.name, ms: $0.ms) }
        )
    }
}

/// `TopicDetail`: the response of getTopic, createTopic, updateTopic, archive, unarchive and
/// publishTopicVersion, and the record in a feed `topic` item.
public struct TopicDetailDTO: Codable, Sendable, Hashable, WireResponse {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String
    public var status: TopicStatus
    public var currentVersion: Int
    public var revision: Int
    public var questionCount: Int
    public var entryCount: Int
    @RequiredKey public var lastCapturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    @RequiredKey public var archivedAt: Date?
    @RequiredKey public var schedule: ScheduleDTO?
    @RequiredKey public var scheduleUpdatedAt: Date?
    @RequiredKey public var due: DueStatusDTO?
    @RequiredKey public var timer: TopicTimerDTO?
    public var questions: [QuestionDTO]

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, status, revision, schedule, due, timer, questions
        case currentVersion = "current_version"
        case questionCount = "question_count"
        case entryCount = "entry_count"
        case lastCapturedAt = "last_captured_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case scheduleUpdatedAt = "schedule_updated_at"
    }

    public func toDomain() throws -> Topic {
        Topic(
            id: try .wire(id, "topic.id"), slug: slug, name: name, description: description, status: status,
            currentVersion: currentVersion, revision: revision, questionCount: questionCount, entryCount: entryCount,
            lastCapturedAt: lastCapturedAt, createdAt: createdAt, updatedAt: updatedAt, archivedAt: archivedAt,
            schedule: try schedule?.toDomain(), scheduleUpdatedAt: scheduleUpdatedAt, due: due?.toDomain(),
            timer: timer?.toDomain(), questions: try questions.toDomain())
    }
}

/// `TopicSummary`: an item of listTopics.
public struct TopicSummaryDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String
    public var status: TopicStatus
    public var currentVersion: Int
    public var revision: Int
    public var questionCount: Int
    public var entryCount: Int
    @RequiredKey public var lastCapturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    @RequiredKey public var archivedAt: Date?
    @RequiredKey public var schedule: ScheduleDTO?
    @RequiredKey public var scheduleUpdatedAt: Date?
    @RequiredKey public var due: DueStatusDTO?
    @RequiredKey public var timer: TopicTimerDTO?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, status, revision, schedule, due, timer
        case currentVersion = "current_version"
        case questionCount = "question_count"
        case entryCount = "entry_count"
        case lastCapturedAt = "last_captured_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case scheduleUpdatedAt = "schedule_updated_at"
    }

    public func toDomain() throws -> TopicSummary {
        TopicSummary(
            id: try .wire(id, "topic.id"), slug: slug, name: name, description: description, status: status,
            currentVersion: currentVersion, revision: revision, questionCount: questionCount, entryCount: entryCount,
            lastCapturedAt: lastCapturedAt, createdAt: createdAt, updatedAt: updatedAt, archivedAt: archivedAt,
            schedule: try schedule?.toDomain(), scheduleUpdatedAt: scheduleUpdatedAt, due: due?.toDomain(),
            timer: timer?.toDomain())
    }
}

/// `TopicPage` (listTopics) and `EntryPage` (listEntries).
public struct PageDTO<Item: Codable & DomainConvertible & Hashable>: Codable, Sendable, Hashable, WireResponse
where Item.Domain: Hashable {
    public var items: [Item]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public func toDomain() throws -> Page<Item.Domain> {
        Page(items: try items.toDomain(), total: total, limit: limit, offset: offset)
    }
}

/// `TopicVersionOut`: an item of listTopicVersions and the record in a feed `version` item.
public struct TopicVersionDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var version: Int
    public var questions: [QuestionDTO]
    @RequiredKey public var timer: TopicTimerDTO?
    public var changeNote: String
    public var createdAt: Date
    public var entryCount: Int

    enum CodingKeys: String, CodingKey {
        case version, questions, timer
        case changeNote = "change_note"
        case createdAt = "created_at"
        case entryCount = "entry_count"
    }

    public func toDomain() throws -> TopicVersion {
        TopicVersion(
            version: version, questions: try questions.toDomain(), timer: timer?.toDomain(), changeNote: changeNote,
            createdAt: createdAt, entryCount: entryCount)
    }
}

/// `CompatibilityReport` (checkTopicVersion).
public struct CompatibilityReportDTO: Codable, Sendable, Hashable, WireResponse {
    public var ok: Bool
    public var nextVersion: Int
    public var issues: [Issue]
    public var changes: [Change]

    enum CodingKeys: String, CodingKey {
        case ok, issues, changes
        case nextVersion = "next_version"
    }

    public struct Issue: Codable, Sendable, Hashable {
        public var level: CompatibilityReport.Level
        @RequiredKey public var questionKey: String?
        public var message: String

        enum CodingKeys: String, CodingKey {
            case level, message
            case questionKey = "question_key"
        }
    }

    public struct Change: Codable, Sendable, Hashable {
        public var kind: CompatibilityReport.ChangeKind
        public var questionKey: String
        public var details: [String]

        enum CodingKeys: String, CodingKey {
            case kind, details
            case questionKey = "question_key"
        }
    }

    public func toDomain() -> CompatibilityReport {
        CompatibilityReport(
            ok: ok, nextVersion: nextVersion,
            issues: issues.map { .init(level: $0.level, questionKey: $0.questionKey, message: $0.message) },
            changes: changes.map { .init(kind: $0.kind, questionKey: $0.questionKey, details: $0.details) })
    }
}
