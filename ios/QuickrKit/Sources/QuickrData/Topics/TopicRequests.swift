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

    /// The Details save (`MetaForm`): only the changed fields (``TopicDetailsChange``).
    public static func details(_ change: TopicDetailsChange) -> TopicUpdateDTO {
        TopicUpdateDTO(name: change.name, slug: change.slug, description: change.description)
    }

    /// The Schedule save (`ScheduleForm`): `{schedule}`, where null removes it.
    public static func schedule(_ schedule: Schedule?) -> TopicUpdateDTO {
        TopicUpdateDTO(schedule: schedule.map { .value(ScheduleInputDTO($0)) } ?? .null)
    }
}

extension TopicRequests {
    /// `VersionDraft` for "Review changes" (`EditQuestionsPage.onReview`): the validated questions
    /// and the version they were edited from, so a newer one answers 409.
    public static func versionCheck(_ version: TopicDraft.Version, baseVersion: Int) -> VersionDraftDTO {
        VersionDraftDTO(questions: version.questions, baseVersion: baseVersion)
    }

    /// `VersionCreate` for "Publish": the reviewed questions, the same base, and the change note as
    /// typed in the review (`.trim()`ed; empty is sent as is, like the PWA).
    public static func publish(_ version: TopicDraft.Version, baseVersion: Int, changeNote: String) -> VersionCreateDTO
    {
        VersionCreateDTO(
            questions: version.questions, baseVersion: baseVersion, changeNote: JSNumber.trim(changeNote))
    }
}
