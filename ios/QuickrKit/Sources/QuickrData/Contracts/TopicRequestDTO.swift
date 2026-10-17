import QuickrCore

/// `TopicCreate` (createTopic).
public struct TopicCreateDTO: Codable, Sendable, Hashable {
    public var name: String
    public var slug: String?
    public var description: String?
    public var questions: [QuestionInputDTO]
    public var schedule: ScheduleInputDTO?

    public init(
        name: String, slug: String? = nil, description: String? = nil, questions: [Question],
        schedule: Schedule? = nil
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.questions = questions.map(QuestionInputDTO.init)
        self.schedule = schedule.map(ScheduleInputDTO.init)
    }
}

/// `TopicUpdate` (updateTopic). `schedule` is three-state: absent keeps it, `null` removes it.
public struct TopicUpdateDTO: Codable, Sendable, Hashable {
    public var name: String?
    public var slug: String?
    public var description: String?
    public var schedule: Nullable<ScheduleInputDTO>
    public var expectedRevision: Int?

    enum CodingKeys: String, CodingKey {
        case name, slug, description, schedule
        case expectedRevision = "expected_revision"
    }

    public init(
        name: String? = nil, slug: String? = nil, description: String? = nil,
        schedule: Nullable<ScheduleInputDTO> = .absent, expectedRevision: Int? = nil
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.schedule = schedule
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        schedule = try container.decodeNullable(ScheduleInputDTO.self, forKey: .schedule)
        expectedRevision = try container.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(slug, forKey: .slug)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(schedule, forKey: .schedule)
        try container.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
    }
}

/// `VersionCreate` (publishTopicVersion). Online only: the 409 on a stale `base_version` must be
/// seen live (sync-protocol.md §11).
public struct VersionCreateDTO: Codable, Sendable, Hashable {
    public var questions: [QuestionInputDTO]
    public var baseVersion: Int
    public var changeNote: String?

    enum CodingKeys: String, CodingKey {
        case questions
        case baseVersion = "base_version"
        case changeNote = "change_note"
    }

    public init(questions: [Question], baseVersion: Int, changeNote: String? = nil) {
        self.questions = questions.map(QuestionInputDTO.init)
        self.baseVersion = baseVersion
        self.changeNote = changeNote
    }
}

/// `VersionDraft` (checkTopicVersion).
public struct VersionDraftDTO: Codable, Sendable, Hashable {
    public var questions: [QuestionInputDTO]
    public var baseVersion: Int?

    enum CodingKeys: String, CodingKey {
        case questions
        case baseVersion = "base_version"
    }

    public init(questions: [Question], baseVersion: Int?) {
        self.questions = questions.map(QuestionInputDTO.init)
        self.baseVersion = baseVersion
    }
}
