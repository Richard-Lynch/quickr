import Foundation
import QuickrCore
import QuickrUI
import Testing

/// A scripted `TopicWriter`: records what the screen asked for and answers as told.
@MainActor
final class FakeTopicWriter: TopicWriter {
    enum Call: Equatable {
        case create(name: String, schedule: Schedule?)
        case details(TopicDetailsChange)
        case schedule(Schedule?)
        case delete
        case archive(Bool, baseRevision: Int)
    }

    var calls: [Call] = []
    var topicResult: TopicWriteOutcome<Topic>?
    var deleteResult: TopicWriteOutcome<Void> = .done(())
    var unsynced = 0
    var archiveError: (any Error)?
    /// The server's copy after a successful PATCH (built from the change when nil).
    var server: Topic

    init(server: Topic) { self.server = server }

    func create(_ creation: TopicDraft.Creation, schedule: Schedule?) async -> TopicWriteOutcome<Topic> {
        calls.append(.create(name: creation.name, schedule: schedule))
        return topicResult ?? .done(server)
    }

    func saveDetails(_ change: TopicDetailsChange, topicId: UUID) async -> TopicWriteOutcome<Topic> {
        calls.append(.details(change))
        if let topicResult { return topicResult }
        server.name = change.name ?? server.name
        server.slug = change.slug ?? server.slug
        server.description = change.description ?? server.description
        server.revision += 1
        return .done(server)
    }

    func saveSchedule(_ schedule: Schedule?, topicId: UUID) async -> TopicWriteOutcome<Topic> {
        calls.append(.schedule(schedule))
        if let topicResult { return topicResult }
        server.schedule = schedule
        server.scheduleUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        server.revision += 1
        return .done(server)
    }

    func delete(topicId: UUID) async -> TopicWriteOutcome<Void> {
        calls.append(.delete)
        return deleteResult
    }

    func unsyncedChanges(topicId: UUID) async -> Int { unsynced }

    func setArchived(_ archived: Bool, topicId: UUID, baseRevision: Int) async throws {
        calls.append(.archive(archived, baseRevision: baseRevision))
        if let archiveError { throw archiveError }
    }
}

@MainActor @Suite struct TopicSettingsModelTests {
    struct Refused: Error, CustomStringConvertible {
        var description: String { "quickR switched to another server." }
    }

    static let topic = Topic(
        id: UUID(), slug: "mood", name: "Mood", description: "How do you feel", currentVersion: 1, revision: 3,
        questionCount: 1, entryCount: 12, createdAt: .distantPast, updatedAt: .distantPast,
        questions: [Question(key: "mood", label: "Mood", kind: .int(.init(min: 1, max: 5)))])
    static let daily = Schedule.daily(.init(times: [TimeOfDay("08:00")!], days: [1, 2, 3, 4, 5], timezone: "UTC"))

    let writer: FakeTopicWriter
    let toasts = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let model: TopicSettingsModel
    var slugChanges: [String] { slugLog.values }
    let slugLog = Log()
    let deleted = Log()

    @MainActor final class Log {
        var values: [String] = []
    }

    init() {
        writer = FakeTopicWriter(server: Self.topic)
        let slugLog = slugLog
        let deleted = deleted
        model = TopicSettingsModel(
            topic: Self.topic, writer: writer, toasts: toasts, deviceTimeZone: "Europe/London",
            onSlugChanged: { slugLog.values.append($0) }, onDeleted: { deleted.values.append("deleted") })
    }

    var titles: [String] { toasts.items.map(\.toast.title) }

    // MARK: Details

    /// TP6: each save is a new attempt, so the same banner is read again (`qrAnnouncesError`).
    @Test func eachSaveIsANewAttempt() async {
        writer.topicResult = .offline
        model.name = "Feelings"
        await model.saveDetails()
        await model.saveDetails()
        #expect(model.detailsAttempts == 2)
        #expect(model.detailsBanner == TopicWriteMessage.offline)
        model.schedule.kind = .daily
        await model.saveSchedule()
        await model.saveSchedule()
        #expect(model.scheduleAttempts == 2)
        #expect(model.scheduleBanner == TopicWriteMessage.offline)
    }

    @Test func detailsStartCleanAndSaveOnlyWhatChanged() async {
        #expect(!model.detailsDirty)
        model.description = "Feelings, daily"
        #expect(model.detailsDirty)
        await model.saveDetails()
        #expect(writer.calls == [.details(TopicDetailsChange(description: "Feelings, daily"))])
        #expect(titles == ["Saved"])
        #expect(!model.detailsDirty)
        #expect(model.topic.description == "Feelings, daily")
        #expect(slugChanges.isEmpty)
    }

    @Test func onlyWhitespaceDifferenceIsNothingToSave() async {
        model.name = "  Mood "
        await model.saveDetails()
        #expect(writer.calls.isEmpty)
        #expect(titles == ["Nothing to save"])
    }

    @Test func invalidDetailsStayLocal() async {
        model.name = "   "
        model.slug = "Not A Slug"
        await model.saveDetails()
        #expect(writer.calls.isEmpty)
        #expect(model.detailErrors[.name] == BuilderMessage.topicName)
        #expect(model.detailErrors[.slug] == BuilderMessage.slug)
    }

    @Test func aNewSlugMovesTheScreen() async {
        model.slug = "feelings"
        await model.saveDetails()
        #expect(slugChanges == ["feelings"])
        #expect(model.topic.slug == "feelings")
    }

    @Test func aTakenSlugLandsOnTheSlugField() async {
        writer.topicResult = .rejected(Problem(code: .conflict, detail: "slug 'water' is already taken"))
        model.slug = "water"
        await model.saveDetails()
        #expect(model.detailErrors[.slug] == "Slug 'water' is already taken")
        #expect(model.detailsBanner == nil)
        #expect(model.detailsDirty, "the edit stays")
    }

    @Test func offlineDetailsSayNeedsAConnection() async {
        writer.topicResult = .offline
        model.name = "Feelings"
        await model.saveDetails()
        #expect(model.detailsBanner == TopicWriteMessage.offline)
        #expect(model.name == "Feelings")
        #expect(titles.isEmpty)
    }

    @Test func aNewerTopicResetsCleanSectionsOnlyWhenTheirValuesChanged() {
        model.description = "editing"
        var newer = Self.topic
        newer.status = .archived  // an archive: details untouched
        model.topicChanged(newer)
        #expect(model.description == "editing")
        newer.name = "Renamed elsewhere"
        model.topicChanged(newer)
        #expect(model.name == "Renamed elsewhere")
        #expect(model.description == "How do you feel", "the form starts over from the new values")
    }

    // MARK: Schedule

    @Test func aScheduleIsSavedAndTheFormIsCleanAfter() async {
        #expect(model.schedule.kind == .none)
        #expect(!model.scheduleDirty)
        model.schedule.kind = .daily
        model.schedule.days = [1, 2, 3, 4, 5]
        model.schedule.timezone = "UTC"
        #expect(model.scheduleDirty)
        #expect(model.schedulePreview == "Daily 08:00 · weekdays")
        await model.saveSchedule()
        #expect(writer.calls == [.schedule(Self.daily)])
        #expect(titles == ["Schedule saved"])
        #expect(!model.scheduleDirty)
        #expect(model.topic.schedule == Self.daily)
    }

    @Test func afterASaveTheFormReopensFromTheSavedSchedule() async {
        model.schedule.kind = .interval
        model.schedule.every = "120"
        model.schedule.unit = .minutes
        await model.saveSchedule()
        #expect(writer.calls == [.schedule(.interval(.init(everyMinutes: 120, timezone: "Europe/London")))])
        #expect(model.schedule.every == "2" && model.schedule.unit == .hours, "the PWA's form remounts")
        #expect(!model.scheduleDirty)
    }

    @Test func choosingNoneRemovesTheSchedule() async {
        var scheduled = Self.topic
        scheduled.schedule = Self.daily
        model.topicChanged(scheduled)
        #expect(model.schedule.kind == .daily)
        model.schedule.kind = .none
        await model.saveSchedule()
        #expect(writer.calls == [.schedule(nil)])
        #expect(titles == ["Schedule removed"])
    }

    @Test func anInvalidScheduleIsNotSentAndRevalidatesAsItIsFixed() async {
        model.schedule.kind = .interval
        model.schedule.every = "0"
        await model.saveSchedule()
        #expect(writer.calls.isEmpty)
        #expect(model.scheduleErrors == [.every: ScheduleMessage.wholeNumber])
        model.schedule.every = "2"
        #expect(model.scheduleErrors.isEmpty, "fixed as typed, after a failed save")
        #expect(model.schedulePreview == "Every 2 days")
    }

    @Test func serverScheduleErrorsLandOnTheirFields() async {
        writer.topicResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "Request validation failed",
                errors: [FieldIssue(location: [.key("body"), .key("schedule"), .key("timezone")], message: "bad zone")])
        )
        model.schedule.kind = .daily
        await model.saveSchedule()
        #expect(model.scheduleErrors == [.timezone: "Bad zone"])
        #expect(model.scheduleBanner == nil)
    }

    @Test func resetGoesBackToTheSavedSchedule() {
        model.schedule.kind = .interval
        model.resetSchedule()
        #expect(model.schedule.kind == .none)
        #expect(!model.scheduleDirty)
    }

    // MARK: Archive

    @Test func archiveIsQueuedWithUndo() async throws {
        await model.archive()
        #expect(writer.calls == [.archive(true, baseRevision: 3)])
        let toast = try #require(toasts.items.last?.toast)
        #expect(toast.title == "Topic archived")
        #expect(toast.message == "Hidden from the list; no new entries.")
        #expect(toast.action?.label == "Undo")

        toast.action?.perform()
        try await waitUntil { writer.calls.count == 2 }
        #expect(writer.calls.last == .archive(false, baseRevision: 3))
        #expect(toasts.items.last?.toast.title == "Topic unarchived")
        #expect(toasts.items.last?.toast.action == nil, "no Undo for the Undo")
    }

    @Test func unarchiveHasNoUndo() async {
        var archived = Self.topic
        archived.status = .archived
        model.topicChanged(archived)
        await model.unarchive()
        #expect(writer.calls == [.archive(false, baseRevision: 3)])
        #expect(toasts.items.last?.toast.title == "Topic unarchived")
        #expect(toasts.items.last?.toast.action == nil)
    }

    @Test func aRefusedArchiveSaysSo() async {
        writer.archiveError = Refused()
        await model.archive()
        #expect(toasts.items.last?.toast.title == "Failed")
        #expect(toasts.items.last?.toast.tone == .danger)
    }

    // MARK: Delete

    @Test func deleteNeedsTheSlugTypedAndWarnsAboutUnsyncedChanges() async {
        writer.unsynced = 2
        model.deleteConfirmation = "leftover"
        await model.prepareDelete()
        #expect(model.deleteConfirmation == "")
        #expect(model.unsyncedWarning == "2 unsynced changes for this topic will be lost.")
        #expect(!model.canConfirmDelete)
        model.deleteConfirmation = "moo"
        #expect(!model.canConfirmDelete)
        #expect(await model.delete() == false)
        #expect(writer.calls.isEmpty)
        model.deleteConfirmation = " mood "
        #expect(model.canConfirmDelete, "surrounding spaces don't count")
        #expect(await model.delete())
        #expect(writer.calls == [.delete])
        #expect(titles == ["Topic deleted"])
        #expect(deleted.values == ["deleted"])
    }

    @Test func aFailedDeleteStaysAndSaysWhy() async {
        writer.deleteResult = .rejected(Problem(code: .conflict, detail: "archive the topic before deleting it"))
        model.deleteConfirmation = "mood"
        #expect(await model.delete() == false)
        #expect(toasts.items.last?.toast.title == "Delete failed")
        #expect(toasts.items.last?.toast.message == "Archive the topic before deleting it")
        #expect(deleted.values.isEmpty)

        writer.deleteResult = .offline
        #expect(await model.delete() == false)
        #expect(toasts.items.last?.toast.message == TopicWriteMessage.offline)
    }

    @Test func noUnsyncedChangesNoWarning() async {
        await model.prepareDelete()
        #expect(model.unsyncedWarning == nil)
        #expect(
            model.deleteText(entries: "12 entries")
                == "This permanently deletes Mood, all 12 entries and every version. There is no undo.")
    }
}

/// Waits (bounded) for a condition the main actor will make true.
@MainActor
func waitUntil(_ condition: () -> Bool, within: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + within
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            return
        }
        await Task.yield()
    }
}
