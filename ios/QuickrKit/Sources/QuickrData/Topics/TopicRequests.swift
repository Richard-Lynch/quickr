import QuickrCore

/// The bodies the topic screens send, as the PWA builds them (`NewTopicPage`, `SettingsPage`).
/// Only the Details save carries `expected_revision` (``details(_:expectedRevision:)``), as the
/// PWA's `MetaForm` does; create and schedule saves don't.
public enum TopicRequests {
    /// `TopicCreate` (`makeTopicDraftSchema`'s output): BUILDER's validated draft plus the schedule
    /// (nil: none) and the appearance (left out when empty: the server's defaults). An empty slug
    /// was already turned into nil (the server derives it).
    public static func create(
        _ creation: TopicDraft.Creation, schedule: Schedule?, appearance: TopicAppearance = .empty
    ) -> TopicCreateDTO {
        TopicCreateDTO(
            name: creation.name, slug: creation.slug, description: creation.description,
            questions: creation.questions, schedule: schedule, timer: creation.timer,
            appearance: appearance == .empty ? nil : appearance)
    }

    /// The Details save (`MetaForm`): only the changed fields (``TopicDetailsChange``), the
    /// appearance's among them, in one PATCH.
    public static func details(_ change: TopicDetailsChange) -> TopicUpdateDTO {
        TopicUpdateDTO(
            name: change.name, slug: change.slug, description: change.description,
            appearance: change.appearance.map(AppearanceUpdateDTO.init))
    }

    /// The Details save with `expected_revision` (appearance.md §1.1, §7): the revision on screen,
    /// so a topic changed elsewhere meanwhile answers 409 `stale_revision` instead of having its
    /// appearance overwritten.
    public static func details(_ change: TopicDetailsChange, expectedRevision: Int) -> TopicUpdateDTO {
        var body = details(change)
        body.expectedRevision = expectedRevision
        return body
    }

    /// The Schedule save (`ScheduleForm`): `{schedule}`, where null removes it.
    public static func schedule(_ schedule: Schedule?) -> TopicUpdateDTO {
        TopicUpdateDTO(schedule: schedule.map { .value(ScheduleInputDTO($0)) } ?? .null)
    }
}

extension TopicRequests {
    /// `VersionDraft` for "Review changes" (`EditQuestionsPage.onReview`): the validated questions,
    /// the draft's timer (so a timer-only change isn't "no changes", timers.md §2.1) and the version
    /// they were edited from, so a newer one answers 409.
    public static func versionCheck(_ version: TopicDraft.Version, baseVersion: Int) -> VersionDraftDTO {
        VersionDraftDTO(questions: version.questions, baseVersion: baseVersion, timer: version.timer)
    }

    /// `VersionCreate` for "Publish": the reviewed questions and timer, the same base, and the
    /// change note as typed in the review (`.trim()`ed; empty is sent as is, like the PWA).
    public static func publish(_ version: TopicDraft.Version, baseVersion: Int, changeNote: String)
        -> VersionCreateDTO
    {
        VersionCreateDTO(
            questions: version.questions, baseVersion: baseVersion, timer: version.timer,
            changeNote: JSNumber.trim(changeNote))
    }
}
