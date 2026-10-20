import Foundation
import Observation
import QuickrCore

/// Topic settings (`/t/:ref/settings`, the PWA's `SettingsPage`): Details, Schedule and Lifecycle.
///
/// - **Details** (name, slug, description) and **Schedule** save online only (`PATCH`), each with
///   its own Save; the server's errors land on the fields, the rest in the section's banner.
/// - **Archive** is queued (it works offline) and offers Undo; **Unarchive** doesn't.
/// - **Delete** is for archived topics only, after typing the slug; it warns about unsynced
///   changes that would be lost, and is online only.
@MainActor @Observable
public final class TopicSettingsModel {
    public private(set) var topic: Topic

    // MARK: Details

    public var name: String
    public var slug: String
    public var description: String
    public private(set) var detailErrors: [DraftField: String] = [:]
    public private(set) var detailsBanner: String?
    public private(set) var isSavingDetails = false

    // MARK: Schedule

    public var schedule: ScheduleDraft {
        didSet { if schedule != oldValue { scheduleChanged() } }
    }
    public private(set) var scheduleErrors: [ScheduleField: String] = [:]
    public private(set) var scheduleBanner: String?
    public private(set) var isSavingSchedule = false
    /// After a failed save, edits revalidate as they happen (`reValidateMode: 'onChange'`).
    private var scheduleSubmitted = false

    // MARK: Lifecycle

    public private(set) var isChangingArchive = false
    /// The typed slug in the delete sheet.
    public var deleteConfirmation = ""
    public private(set) var isDeleting = false
    /// The topic's queued or failed changes, read when the delete sheet opens.
    public private(set) var unsyncedChanges = 0

    public let limits: Limits
    @ObservationIgnored private let writer: any TopicWriter
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let deviceTimeZone: String
    @ObservationIgnored private let isKnownTimeZone: (String) -> Bool
    /// The slug changed: the screen's link becomes `/t/{slug}/settings`.
    @ObservationIgnored private let onSlugChanged: @MainActor (String) -> Void
    /// The topic is gone: back to the topic list.
    @ObservationIgnored private let onDeleted: @MainActor () -> Void

    public init(
        topic: Topic, writer: any TopicWriter, toasts: ToastCenter, limits: Limits = .serverDefaults,
        deviceTimeZone: String = TimeZone.current.identifier,
        isKnownTimeZone: @escaping (String) -> Bool = ScheduleDraft.isKnownTimeZone,
        onSlugChanged: @escaping @MainActor (String) -> Void = { _ in }, onDeleted: @escaping @MainActor () -> Void = {}
    ) {
        self.topic = topic
        self.writer = writer
        self.toasts = toasts
        self.limits = limits
        self.deviceTimeZone = deviceTimeZone
        self.isKnownTimeZone = isKnownTimeZone
        self.onSlugChanged = onSlugChanged
        self.onDeleted = onDeleted
        name = topic.name
        slug = topic.slug
        description = topic.description
        schedule = ScheduleDraft(schedule: topic.schedule, timezone: deviceTimeZone)
    }

    public var isArchived: Bool { topic.status == .archived }

    /// The store has a newer copy of the topic (a sync, an archive). Like the PWA's forms, which
    /// are keyed by the saved values, a section whose saved values changed starts over from them.
    public func topicChanged(_ newer: Topic) {
        let old = topic
        topic = newer
        if (old.name, old.slug, old.description) != (newer.name, newer.slug, newer.description) {
            resetDetails()
        }
        if old.scheduleUpdatedAt != newer.scheduleUpdatedAt || old.schedule != newer.schedule {
            resetSchedule()
        }
    }

    // MARK: - Details

    public var detailsDirty: Bool {
        name != topic.name || slug != topic.slug || description != topic.description
    }

    public func resetDetails() {
        name = topic.name
        slug = topic.slug
        description = topic.description
        detailErrors = [:]
        detailsBanner = nil
    }

    /// "Save details": validates like the form, sends only the changed fields.
    public func saveDetails() async {
        guard !isSavingDetails else { return }
        detailsBanner = nil
        let draft = TopicDraft.editing(name: name, slug: slug, description: description, questions: topic.questions)
        let details: TopicDraft.Details
        switch draft.validatedDetails(limits: limits) {
        case .failure(let issues):
            detailErrors = issues.byField
            return
        case .success(let valid):
            details = valid
            detailErrors = [:]
        }
        guard let change = TopicDetailsChange(details, from: topic) else {
            toasts.show(Toast("Nothing to save", tone: .info))
            return
        }
        isSavingDetails = true
        defer { isSavingDetails = false }
        let outcome = await writer.saveDetails(change, topicId: topic.id)
        switch outcome {
        case .done(let updated):
            let slugChanged = updated.slug != topic.slug
            topic = updated
            resetDetails()
            toasts.show(Toast("Saved"))
            if slugChanged { onSlugChanged(updated.slug) }
        case .rejected(let problem?):
            let mapped = TopicProblemMapping.details(problem)
            detailErrors = Dictionary(uniqueKeysWithValues: mapped.fields.map { (DraftField($0.key), $0.value) })
            detailsBanner = mapped.banner
        default:
            detailsBanner = outcome.message ?? "The server refused the change."
        }
    }

    // MARK: - Schedule

    /// The draft the saved schedule opens as.
    private var savedSchedule: ScheduleDraft { ScheduleDraft(schedule: topic.schedule, timezone: deviceTimeZone) }

    public var scheduleDirty: Bool { schedule != savedSchedule }

    /// "Reset": back to the saved schedule.
    public func resetSchedule() {
        schedule = savedSchedule
        scheduleErrors = [:]
        scheduleBanner = nil
        scheduleSubmitted = false
    }

    private func scheduleChanged() {
        guard scheduleSubmitted else { return }
        scheduleErrors = validateSchedule().failureIssues
    }

    private func validateSchedule() -> Result<Schedule?, ScheduleIssues> {
        schedule.validated(limits: limits, isKnownTimeZone: isKnownTimeZone)
    }

    /// The line under the editor.
    public var schedulePreview: String { schedule.preview(limits: limits, isKnownTimeZone: isKnownTimeZone) }

    /// "Save schedule": sets it, or removes it when the kind is None.
    public func saveSchedule() async {
        guard !isSavingSchedule else { return }
        scheduleBanner = nil
        scheduleSubmitted = true
        let value: Schedule?
        switch validateSchedule() {
        case .failure(let issues):
            scheduleErrors = issues.byField
            return
        case .success(let valid):
            value = valid
            scheduleErrors = [:]
        }
        isSavingSchedule = true
        defer { isSavingSchedule = false }
        let outcome = await writer.saveSchedule(value, topicId: topic.id)
        switch outcome {
        case .done(let updated):
            // The PWA's form is keyed by `schedule_updated_at`: it reopens from the saved schedule.
            topic = updated
            resetSchedule()
            toasts.show(Toast(value == nil ? "Schedule removed" : "Schedule saved"))
        case .rejected(let problem?):
            let mapped = TopicProblemMapping.schedule(problem)
            scheduleErrors = mapped.fields
            scheduleBanner = mapped.banner
        default:
            scheduleBanner = outcome.message ?? "The server refused the change."
        }
    }

    // MARK: - Archive

    /// "Archive topic": queued at once (the list hides it), with Undo.
    public func archive() async {
        await setArchived(true, undoable: true)
    }

    /// "Unarchive" (no Undo, like the PWA).
    public func unarchive() async {
        await setArchived(false, undoable: false)
    }

    private func setArchived(_ archived: Bool, undoable: Bool) async {
        guard !isChangingArchive else { return }
        isChangingArchive = true
        defer { isChangingArchive = false }
        do {
            try await writer.setArchived(archived, topicId: topic.id, baseRevision: topic.revision)
        } catch {
            toasts.show(Toast("Failed", message: String(describing: error), tone: .danger))
            return
        }
        if undoable {
            toasts.show(
                Toast(
                    archived ? "Topic archived" : "Topic unarchived", message: "Hidden from the list; no new entries.",
                    action: Toast.Action("Undo") { [weak self] in
                        guard let self else { return }
                        Task { await self.setArchived(!archived, undoable: false) }
                    }))
        } else {
            toasts.show(Toast(archived ? "Topic archived" : "Topic unarchived"))
        }
    }

    // MARK: - Delete

    /// The delete sheet's body.
    public func deleteText(entries: String) -> String {
        "This permanently deletes \(topic.name), all \(entries) and every version. There is no undo."
    }

    /// "_N_ unsynced changes for this topic will be lost." (sync-protocol.md §11), or nil.
    public var unsyncedWarning: String? {
        switch unsyncedChanges {
        case 0: nil
        case 1: "1 unsynced change for this topic will be lost."
        default: "\(unsyncedChanges) unsynced changes for this topic will be lost."
        }
    }

    /// "Delete topic" enables once the slug is typed (surrounding spaces don't count).
    public var canConfirmDelete: Bool { JSNumber.trim(deleteConfirmation) == topic.slug && !isDeleting }

    /// The delete sheet opens: a fresh confirmation field, and the unsynced count.
    public func prepareDelete() async {
        deleteConfirmation = ""
        unsyncedChanges = await writer.unsyncedChanges(topicId: topic.id)
    }

    /// Deletes the topic (online only). Returns true when it's gone (the sheet closes and the
    /// screen leaves).
    @discardableResult
    public func delete() async -> Bool {
        guard canConfirmDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }
        let outcome = await writer.delete(topicId: topic.id)
        switch outcome {
        case .done:
            toasts.show(Toast("Topic deleted"))
            onDeleted()
            return true
        case .rejected(let problem):
            toasts.show(
                Toast(
                    "Delete failed", message: problem.map(ProblemMapping.banner(for:)) ?? "The server refused it.",
                    tone: .danger))
        default:
            toasts.show(Toast("Delete failed", message: outcome.message, tone: .danger))
        }
        return false
    }
}

extension Result where Failure == ScheduleIssues {
    var failureIssues: [ScheduleField: String] {
        if case .failure(let issues) = self { return issues.byField }
        return [:]
    }
}

extension DraftField {
    /// The Details form's field for a settings field.
    init(_ field: TopicDetailsField) {
        switch field {
        case .name: self = .name
        case .slug: self = .slug
        case .description: self = .description
        }
    }
}
