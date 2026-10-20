import QuickrCore

/// The bodies the topic screens send, as the PWA builds them (`NewTopicPage`, `SettingsPage`).
/// None carries `expected_revision`: the PWA's create, details and schedule saves don't either.
public enum TopicRequests {
    /// `TopicCreate` (`makeTopicDraftSchema`'s output): BUILDER's validated draft plus the schedule
    /// (nil: none). An empty slug was already turned into nil (the server derives it).
    public static func create(_ creation: TopicDraft.Creation, schedule: Schedule?) -> TopicCreateDTO {
        TopicCreateDTO(
            name: creation.name, slug: creation.slug, description: creation.description,
            questions: creation.questions, schedule: schedule)
    }

    /// The Details save (`MetaForm`): only the fields that differ from `topic`. Nil means
    /// "Nothing to save".
    public static func details(_ details: TopicDraft.Details, from topic: Topic) -> TopicUpdateDTO? {
        let name = details.name == topic.name ? nil : details.name
        let slug = details.slug == topic.slug ? nil : details.slug
        let description = details.description == topic.description ? nil : details.description
        guard name != nil || slug != nil || description != nil else { return nil }
        return TopicUpdateDTO(name: name, slug: slug, description: description)
    }

    /// The Schedule save (`ScheduleForm`): `{schedule}`, where null removes it.
    public static func schedule(_ schedule: Schedule?) -> TopicUpdateDTO {
        TopicUpdateDTO(schedule: schedule.map { .value(ScheduleInputDTO($0)) } ?? .null)
    }
}
