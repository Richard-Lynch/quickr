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
    /// The copy the Details edits started from: a save diffs against it and sends its revision.
    private var detailsBase: Topic

    // MARK: Details

    public var name: String
    public var slug: String
    public var description: String
    /// The colour, emoji and tags (`AppearanceEditorView`), saved with the details.
    public var appearance: AppearanceDraft
    public private(set) var detailErrors: [DraftField: String] = [:]
    public private(set) var appearanceErrors: [AppearanceField: String] = [:]
    public private(set) var detailsBanner: String?
    /// Counts "Save details" taps: a repeated identical banner is announced again (`qrAnnouncesError`).
    public private(set) var detailsAttempts = 0
    public private(set) var isSavingDetails = false

    // MARK: Schedule

    public var schedule: ScheduleDraft {
        didSet { if schedule != oldValue { scheduleChanged() } }
    }
    public private(set) var scheduleErrors: [ScheduleField: String] = [:]
    public private(set) var scheduleBanner: String?
    /// Counts "Save schedule" taps (as `detailsAttempts`).
    public private(set) var scheduleAttempts = 0
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
        onSlugChanged: @escaping @MainActor (String) -> Void = { _ in },
        onDeleted: @escaping @MainActor () -> Void = {}
    ) {
        self.topic = topic
        detailsBase = topic
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
        appearance = AppearanceDraft(topic.appearance)
        schedule = ScheduleDraft(schedule: topic.schedule, timezone: deviceTimeZone)
    }

    public var isArchived: Bool { topic.status == .archived }

    /// A save's answer, unless the store already brought a newer copy while it was in flight
    /// (that copy includes this save). The Details edits rebase on it as on a synced copy, except
    /// while a Details save is in flight (it rebases when that ends).
    private func adopt(_ updated: Topic) {
        guard updated.revision >= topic.revision else { return }
        topic = updated
        if !isSavingDetails { rebaseDetails(on: updated) }
    }

    /// The store has a newer copy of the topic (a sync, an archive, this screen's own save).
    ///
    /// - **Details** compare field by field, as the PWA's `MetaForm` does: when the newer copy
    ///   changed none of the fields being edited, it becomes the base (the next save sends its
    ///   revision) and the untouched fields take its values; the edits stay. When it changed an
    ///   edited field, the base stays, so the save answers `staleRevision` instead of overwriting
    ///   the other change.
    /// - **Schedule** starts over from the saved schedule when that changed.
    ///
    /// A copy older than the one on screen is ignored: an observation already in flight when this
    /// screen's own save returned would otherwise put the old revision back.
    public func topicChanged(_ newer: Topic) {
        guard newer.revision >= topic.revision else { return }
        let old = topic
        topic = newer
        if !isSavingDetails { rebaseDetails(on: newer) }
        if old.scheduleUpdatedAt != newer.scheduleUpdatedAt || old.schedule != newer.schedule {
            resetSchedule()
        }
    }

    // MARK: - Details

    /// A Details field, compared on its own.
    enum DetailsField: CaseIterable, Hashable {
        case name, slug, description
        case appearance(AppearanceDraft.Part)

        static let allCases: [DetailsField] =
            [.name, .slug, .description] + AppearanceDraft.Part.allCases.map(DetailsField.appearance)

        /// Its name in a message, as on screen.
        var label: String {
            switch self {
            case .name: "name"
            case .slug: "URL slug"
            case .description: "description"
            case .appearance(.color): "colour"
            case .appearance(.icon): "emoji"
            case .appearance(.tags): "tags"
            }
        }
    }

    /// A Details save is sent at most this many times when other changes keep answering
    /// `staleRevision` (the first send included).
    static let maxSaveAttempts = 3

    /// The fields the user has edited since `detailsBase`.
    private var editedFields: [DetailsField] {
        let parts = appearance.edited(from: detailsBase.appearance)
        return DetailsField.allCases.filter { field in
            switch field {
            case .name: name != detailsBase.name
            case .slug: slug != detailsBase.slug
            case .description: description != detailsBase.description
            case .appearance(let part): parts.contains(part)
            }
        }
    }

    /// Those of `fields` that differ between two copies of the topic.
    private static func changed(_ fields: [DetailsField], from a: Topic, to b: Topic) -> [DetailsField] {
        let parts = AppearanceDraft(a.appearance).edited(from: b.appearance)
        return fields.filter { field in
            switch field {
            case .name: a.name != b.name
            case .slug: a.slug != b.slug
            case .description: a.description != b.description
            case .appearance(let part): parts.contains(part)
            }
        }
    }

    /// The fields `change` sends with a value `topic` doesn't hold (code point by code point for
    /// the tags), in the form's order.
    private static func fields(_ change: TopicDetailsChange, differingFrom topic: Topic) -> [DetailsField] {
        DetailsField.allCases.filter { field in
            switch field {
            case .name: change.name.map { $0 != topic.name } ?? false
            case .slug: change.slug.map { $0 != topic.slug } ?? false
            case .description: change.description.map { $0 != topic.description } ?? false
            case .appearance(.color): change.appearance?.color.map { $0 != topic.appearance.color } ?? false
            case .appearance(.icon): change.appearance?.icon.map { $0 != topic.appearance.icon } ?? false
            case .appearance(.tags):
                change.appearance?.tags.map { tags in
                    tags.count != topic.appearance.tags.count
                        || !zip(tags, topic.appearance.tags).allSatisfy {
                            $0.unicodeScalars.elementsEqual($1.unicodeScalars)
                        }
                } ?? false
            }
        }
    }

    /// `newer` becomes the base unless it changed an edited field; the fields not edited take its
    /// values.
    private func rebaseDetails(on newer: Topic) {
        guard Self.changed(editedFields, from: detailsBase, to: newer).isEmpty else { return }
        moveDetailsBase(to: newer)
    }

    /// `newer` becomes the base even when it changed an edited field (a conflict the screen has
    /// shown): the fields not edited take its values, the edits stay, and the next save sends its
    /// revision, so it keeps them.
    private func moveDetailsBase(to newer: Topic) {
        let edited = editedFields
        detailsBase = newer
        for field in DetailsField.allCases where !edited.contains(field) {
            switch field {
            case .name: name = newer.name
            case .slug: slug = newer.slug
            case .description: description = newer.description
            case .appearance(let part): appearance.take(part, from: newer.appearance)
            }
        }
    }

    public var detailsDirty: Bool { !editedFields.isEmpty }

    public func resetDetails() {
        detailsBase = topic
        name = topic.name
        slug = topic.slug
        description = topic.description
        appearance = AppearanceDraft(topic.appearance)
        detailErrors = [:]
        appearanceErrors = [:]
        detailsBanner = nil
    }

    /// "Save details": validates like the form, sends only the changed fields (the appearance's
    /// among them) in one PATCH, with the base's revision. On a `staleRevision` the server's copy
    /// is read again by the topic's id (its slug may have changed):
    ///
    /// - It changed none of the edited fields: the same change goes again on its revision, up to
    ///   ``maxSaveAttempts`` sends in all; then "keeps changing elsewhere" (contention, not a
    ///   conflict).
    /// - It changed an edited field: the conflict names the field(s) and the base moves to it
    ///   (the other fields show it, the edits stay), so the next save is a deliberate overwrite.
    public func saveDetails() async {
        guard !isSavingDetails else { return }
        detailsAttempts += 1
        detailsBanner = nil
        let draft = TopicDraft.editing(
            name: name, slug: slug, description: description, questions: detailsBase.questions)
        let validDetails = draft.validatedDetails(limits: limits)
        let validAppearance = appearance.validated(limits: limits)
        switch validDetails {
        case .failure(let issues): detailErrors = issues.byField
        case .success: detailErrors = [:]
        }
        appearanceErrors = validAppearance.failureFields
        guard case .success(let details) = validDetails, case .success(let newAppearance) = validAppearance else {
            return
        }
        let base = detailsBase
        var change = TopicDetailsChange(details, from: base) ?? TopicDetailsChange()
        change.appearance = AppearanceUpdate(newAppearance, from: base.appearance)
        guard change != TopicDetailsChange() else {
            toasts.show(Toast("Nothing to save", tone: .info))
            return
        }
        // The fields this save sends (not the raw form's: a name that only gained spaces isn't
        // sent), fixed now: copies arriving meanwhile don't move the base.
        let sent = Self.fields(change, differingFrom: base)
        isSavingDetails = true
        let oldSlug = base.slug
        var outcome = await writer.saveDetails(change, topicId: base.id, expectedRevision: base.revision)
        var attempts = 1
        var conflict: (fields: [DetailsField], latest: Topic)?
        var contended = false
        while case .staleRevision = outcome, case .done(let fresh) = await writer.latestTopic(topicId: base.id) {
            adopt(fresh)
            // The fetched copy, or a newer one the store brought while it was read.
            let latest = topic
            // A sent field changed elsewhere to the value being sent is no conflict.
            let conflicting = Self.changed(sent, from: base, to: latest)
                .filter(Self.fields(change, differingFrom: latest).contains)
            if !conflicting.isEmpty {
                conflict = (conflicting, latest)
                break
            }
            guard attempts < Self.maxSaveAttempts else {
                contended = true
                break
            }
            attempts += 1
            outcome = await writer.saveDetails(change, topicId: base.id, expectedRevision: latest.revision)
        }
        let saved = detailsSaved(outcome)
        isSavingDetails = false
        guard saved else {
            if let conflict {
                moveDetailsBase(to: conflict.latest)
                detailsBanner = TopicWriteMessage.conflict(conflict.fields.map(\.label))
            } else if contended {
                detailsBanner = TopicWriteMessage.contention
            }
            // Copies that arrived during the save are considered now.
            rebaseDetails(on: topic)
            return
        }
        resetDetails()
        toasts.show(Toast("Saved"))
        if topic.slug != oldSlug { onSlugChanged(topic.slug) }
    }

    /// Takes the server's copy, or puts its errors on the fields; false when it wasn't saved.
    private func detailsSaved(_ outcome: TopicWriteOutcome<Topic>) -> Bool {
        switch outcome {
        case .done(let updated):
            adopt(updated)
            return true
        case .rejected(var problem?):
            // The `appearance.*` issues go on the editor's fields; the rest map as before.
            var rest: [FieldIssue] = []
            for issue in problem.errors {
                if let field = appearance.field(serverPath: ProblemMapping.path(issue.location)) {
                    appearanceErrors[field] = ProblemMapping.cleanMessage(issue.message)
                } else {
                    rest.append(issue)
                }
            }
            let placedAppearance = rest.count < problem.errors.count
            problem.errors = rest
            let mapped = TopicProblemMapping.details(problem)
            detailErrors = Dictionary(uniqueKeysWithValues: mapped.fields.map { (DraftField($0.key), $0.value) })
            // Every issue on a field: no banner, as for the details' own fields.
            detailsBanner = placedAppearance && rest.isEmpty ? nil : mapped.banner
        default:
            detailsBanner = outcome.message ?? "The server refused the change."
        }
        return false
    }

    // MARK: - Appearance

    public var appearanceDirty: Bool { appearance.differs(from: detailsBase.appearance) }

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
        scheduleAttempts += 1
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
            adopt(updated)
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

extension TopicSettingsModel: AppearanceEditingModel {
    public func setAppearanceError(_ message: String?, for field: AppearanceField) {
        appearanceErrors[field] = message
    }

    public func setAppearanceErrors(_ errors: [AppearanceField: String]) { appearanceErrors = errors }
}
