import Foundation
import QuickrCore

public struct DueStatusDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var isDue: Bool
    public var dueSince: Date?
    public var nextDueAt: Date?
    public var lastEntryAt: Date?

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
    public var lastCapturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var schedule: ScheduleDTO?
    public var scheduleUpdatedAt: Date?
    public var due: DueStatusDTO?
    public var questions: [QuestionDTO]

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, status, revision, schedule, due, questions
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
            questions: try questions.toDomain())
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
    public var lastCapturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var schedule: ScheduleDTO?
    public var scheduleUpdatedAt: Date?
    public var due: DueStatusDTO?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, status, revision, schedule, due
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
            schedule: try schedule?.toDomain(), scheduleUpdatedAt: scheduleUpdatedAt, due: due?.toDomain())
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
    public var changeNote: String
    public var createdAt: Date
    public var entryCount: Int

    enum CodingKeys: String, CodingKey {
        case version, questions
        case changeNote = "change_note"
        case createdAt = "created_at"
        case entryCount = "entry_count"
    }

    public func toDomain() throws -> TopicVersion {
        TopicVersion(
            version: version, questions: try questions.toDomain(), changeNote: changeNote, createdAt: createdAt,
            entryCount: entryCount)
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
        public var questionKey: String?
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
