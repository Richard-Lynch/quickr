import Foundation
import Observation
import QuickrCore

/// The changed fields of an edit: answers by key (nil clears one), captured at, notes, source.
/// Only what changed is set (outbox.md §1: an `entry.update` holds only the changed keys).
public struct EntryPatch: Sendable, Hashable {
    public var answers: [String: AnswerValue?]?
    public var capturedAt: Date?
    public var notes: String?
    public var source: String?

    public init(
        answers: [String: AnswerValue?]? = nil, capturedAt: Date? = nil, notes: String? = nil, source: String? = nil
    ) {
        self.answers = answers
        self.capturedAt = capturedAt
        self.notes = notes
        self.source = source
    }

    public var isEmpty: Bool { answers == nil && capturedAt == nil && notes == nil && source == nil }
}

/// A refused edit to fix (outbox.md §11): its item, what it changed, and why it was refused.
public struct EditFix: Sendable, Hashable {
    public var itemId: String
    public var rowVersion: Int
    public var patch: EntryPatch
    public var problem: Problem?
    /// The failure's message when there's no `Problem` to place.
    public var message: String?

    public init(itemId: String, rowVersion: Int, patch: EntryPatch, problem: Problem?, message: String?) {
        self.itemId = itemId
        self.rowVersion = rowVersion
        self.patch = patch
        self.problem = problem
        self.message = message
    }
}

/// What the edit screen writes through: an update, pinned to the store the entry was read from.
@MainActor
public protocol EntryEditing: AnyObject {
    /// Queues the edit (outbox.md §7.3: `baseRevision` is the server revision the user edited,
    /// nil for an entry the server doesn't have yet). Throws the outbox's errors, or
    /// `EntryWriteError.scopeChanged` once `scope` isn't the active store.
    func update(entryId: UUID, topicId: UUID, patch: EntryPatch, baseRevision: Int?, in scope: EntryScope)
        async throws
    /// Replaces a refused edit's changes and queues it again (CAS on `rowVersion`). `overriding`
    /// holds the fields the user corrected: later queued edits of the entry drop them, so the
    /// correction stays the latest word.
    func fixUpdate(
        itemId: String, rowVersion: Int, entryId: UUID, topicId: UUID, patch: EntryPatch, overriding: EntryPatch,
        in scope: EntryScope
    ) async throws
    /// The refused edit as it is now (another fix moves it), or nil once it is gone or fixed.
    func refusedEdit(itemId: String, questions: [Question], in scope: EntryScope) async throws -> EditFix?
    /// What to tell the user about a refused write.
    func failure(_ error: any Error) -> EntryWriteFailure
}

/// The edit screen (the PWA's `EntryEditPage`): the entry's answers against the questions of the
/// version it was logged with (archived options it holds stay offered), captured at and notes,
/// Save and Delete. Saving queues only what changed, in the store the entry was read from; the
/// outbox merges it into a create the server doesn't have yet (K1) and rebases it on a conflict
/// (§7.4). An entry deleted meanwhile says so and doesn't retry.
@MainActor @Observable
public final class EditModel: EntryDetailsEditing {
    public enum Outcome: Sendable, Hashable {
        case stay
        case leave
    }

    public let topic: Topic
    /// The entry as the form shows it: the store's view of it (queued edits applied); in fix
    /// mode, the entry as it stood before the refused edit, with that edit on top (later queued
    /// edits aren't, so they never leak into the correction).
    public private(set) var entry: Entry
    public private(set) var form: FormModel
    public var capturedAt: Date {
        didSet { capturedAtEdited = true }
    }
    public var notes: String
    /// Editable here (the PWA's edit page), unlike on the record screen.
    public var source: String
    /// A timed entry edits only its notes (the PWA's `meta="notes"`): its time is its run's,
    /// changed through Edit times, and its source is its start's (timers.md §11.1).
    public var sourceIsEditable: Bool { !isTimed }
    public var showsCapturedAt: Bool { !isTimed }
    public var showsSource: Bool { !isTimed }
    /// The entry is a finished run's (timers.md §2.3): `captured_at` is hidden and never sent.
    public var isTimed: Bool { entry.timing != nil }
    /// The run's version's steps (labels for skipped steps, and Edit times' choices).
    public let timerSteps: [TopicTimer.Step]
    /// The open Edit times sheet.
    public var timingEditor: TimingEditModel?
    /// The entry changed elsewhere while the answers or notes are being edited: what it says now.
    /// Shown with Reload; the edits stay until then.
    public private(set) var changedElsewhere: Entry?
    public private(set) var metaErrors: [EntryFormField: String] = [:]
    public var showsDetails = false
    public private(set) var isSaving = false
    /// The entry was deleted (here, elsewhere, or by a sync): nothing to save any more.
    public private(set) var isDeleted = false
    /// Why the last save didn't go through.
    public private(set) var errorMessage: String?
    /// Why the entry's last change didn't sync (shown over the form), if it didn't and there's
    /// nothing to fix here.
    public let syncProblem: String?
    /// A refused edit being fixed: its changes are on the form, its errors on the fields.
    public private(set) var fix: EditFix?
    /// The refusal's message when it had no `Problem` to place.
    public var fixMessage: String? { fix.flatMap { $0.problem == nil ? $0.message : nil } }

    @ObservationIgnored private let writer: any EntryEditing
    @ObservationIgnored private let toasts: EntryToasts
    @ObservationIgnored private let scope: EntryScope
    @ObservationIgnored private var baseRevision: Int?
    @ObservationIgnored private let timingWriter: (any EntryTimingWriting)?
    @ObservationIgnored private let localOnly: Bool
    @ObservationIgnored private let timingClock: TimingEditClock
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var baseline: [String: AnswerInput]
    /// Fix mode: the entry before the refused edit.
    @ObservationIgnored private let fixBase: Entry?
    @ObservationIgnored private var capturedAtEdited = false
    @ObservationIgnored private var saved = false

    /// - Parameters:
    ///   - questions: the questions of the entry's own version.
    ///   - entry: the store's view of the entry; in fix mode, the entry before the refused edit.
    ///   - localOnly: the server doesn't have the entry yet (its create is queued).
    ///   - scope: the store the entry was read from.
    public init(
        topic: Topic, entry: Entry, questions: [Question], localOnly: Bool, syncProblem: String? = nil,
        fix: EditFix? = nil, writer: any EntryEditing, toasts: EntryToasts, scope: EntryScope,
        timerSteps: [TopicTimer.Step] = [], timingWriter: (any EntryTimingWriting)? = nil,
        timingClock: TimingEditClock = .current, limits: Limits = .serverDefaults,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.topic = topic
        self.timerSteps = timerSteps
        self.timingWriter = timingWriter
        self.timingClock = timingClock
        self.localOnly = localOnly
        fixBase = fix == nil ? nil : entry
        let entry = fix.map { entry.applying($0.patch) } ?? entry
        self.entry = entry
        self.syncProblem = syncProblem
        self.writer = writer
        self.toasts = toasts
        self.scope = scope
        baseRevision = localOnly ? nil : entry.revision
        self.limits = limits
        self.now = now
        let form = FormModel(questions: questions, mode: .edit(answers: entry.answers))
        self.form = form
        capturedAt = entry.capturedAt
        notes = entry.notes
        source = entry.source
        baseline = form.inputs
        self.fix = fix
        capturedAtEdited = false
        if let problem = fix?.problem {
            form.apply(problem)
            metaErrors = form.metaErrors
            showsDetails = !metaErrors.isEmpty
        }
    }

    public var isFixing: Bool { fix != nil }

    /// Logged with an older version than the topic's current one: validated with that version's
    /// questions, so historic answers stay consistent.
    public var isOutdated: Bool { entry.version != topic.currentVersion }

    public var hasUnsavedChanges: Bool {
        !saved && !isDeleted
            && (form.inputs != baseline || notes != entry.notes || source != entry.source || capturedAtEdited)
    }

    /// Validates and queues what changed. `.leave` when the screen should close: saved, or nothing
    /// to save.
    public func save() async -> Outcome {
        guard !isSaving, !isDeleted else { return .stay }
        guard let body = form.submit(), case .update(let answers) = body else {
            checkMeta()
            return .stay
        }
        guard checkMeta() else { return .stay }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        if let fix { return await resubmit(fix, answers: answers) }
        let patch = changes(answers)
        guard !patch.isEmpty else { return finish() }
        do {
            try await writer.update(
                entryId: entry.id, topicId: entry.topicId, patch: patch, baseRevision: baseRevision, in: scope)
        } catch {
            switch writer.failure(error) {
            case .notSaved:
                // C0 (outbox.md §8.3): deleted, here or elsewhere. Say so; retrying can't help.
                isDeleted = true
                errorMessage = "This entry was deleted"
            case .scopeChanged:
                errorMessage = "The server changed since this entry was opened. Nothing was saved."
            case .message(let message):
                errorMessage = message
            }
            return .stay
        }
        _ = toasts.center.show(Toast("Entry updated"))
        return finish()
    }

    /// The patch: answers whose value changed (nil for one cleared), captured at if moved, notes
    /// and source if changed.
    func changes(_ answers: [String: AnswerValue?]) -> EntryPatch {
        var changed: [String: AnswerValue?] = [:]
        for (key, value) in answers where value != entry.answers[key] {
            changed[key] = .some(value)
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // A timed entry's captured_at is its run's end, and its source the start's: never sent
        // (the server refuses a captured_at without timing, timers.md §3.8).
        return EntryPatch(
            answers: changed.isEmpty ? nil : changed,
            capturedAt: !isTimed && capturedAtEdited && capturedAt != entry.capturedAt ? capturedAt : nil,
            notes: trimmedNotes != entry.notes ? trimmedNotes : nil,
            source: !isTimed && trimmedSource != entry.source ? trimmedSource : nil)
    }

    /// A fix's patch: the refused edit's changes with the user's corrections on top.
    func fixPatch(_ fix: EditFix, edits: EntryPatch) -> EntryPatch {
        fix.patch.overlaid(by: edits)
    }

    private func resubmit(_ fix: EditFix, answers: [String: AnswerValue?]) async -> Outcome {
        let edits = changes(answers)
        do {
            try await writer.fixUpdate(
                itemId: fix.itemId, rowVersion: fix.rowVersion, entryId: entry.id, topicId: entry.topicId,
                patch: fixPatch(fix, edits: edits), overriding: edits, in: scope)
        } catch {
            errorMessage =
                switch writer.failure(error) {
                case .notSaved: "This entry was deleted"
                case .scopeChanged: "The server changed since this entry was opened. Nothing was saved."
                case .message(let message): message
                }
            // Changed elsewhere meanwhile (a CAS miss): reload it and keep the user's corrections
            // on top of what it says now, for them to check before saving again.
            if let reloaded = try? await writer.refusedEdit(itemId: fix.itemId, questions: form.questions, in: scope),
                reloaded != fix
            {
                reconcile(reloaded, keeping: edits)
                errorMessage =
                    "This change was edited elsewhere meanwhile. Your corrections are kept: check and save again."
            }
            return .stay
        }
        _ = toasts.center.show(Toast("Entry updated", message: "Fixed; it will sync"))
        return finish()
    }

    /// The form over `reloaded`'s changes, with the user's `edits` re-applied on top.
    private func reconcile(_ reloaded: EditFix, keeping edits: EntryPatch) {
        let shown = (fixBase ?? entry).applying(reloaded.patch)
        let fresh = FormModel(questions: form.questions, mode: .edit(answers: shown.answers))
        let freshBaseline = fresh.inputs
        for key in edits.answers?.keys.sorted() ?? [] { _ = fresh.change(key, to: form.input(for: key)) }
        let editedCapturedAt = edits.capturedAt != nil
        entry = shown
        fix = reloaded
        form = fresh
        baseline = freshBaseline
        if edits.notes == nil { notes = shown.notes }
        if edits.source == nil { source = shown.source }
        if !editedCapturedAt {
            capturedAt = shown.capturedAt
            capturedAtEdited = false
        }
    }

    // MARK: Edit times (timers.md §3.8)

    /// Why Edit times isn't offered, if it isn't: the server must have the entry, and saving is
    /// online.
    public var timingEditUnavailable: String? {
        guard let timing = entry.timing else { return nil }
        if localOnly || timingWriter == nil { return "Edit times once this run has synced." }
        // Its steps' labels and choices come from its version's row.
        if timerSteps.isEmpty && timing.segments.contains(where: { $0.kind == .step }) {
            return "Edit times once its version has synced."
        }
        return nil
    }

    /// "Edit times": the sheet over the times as they are now, at the entry's revision.
    public func openTimingEditor() {
        guard let timing = entry.timing, timingEditUnavailable == nil, let timingWriter else { return }
        let editor = TimingEditModel(
            entryId: entry.id, timing: timing, revision: entry.revision, steps: timerSteps, writer: timingWriter,
            clock: timingClock, now: now)
        // A change seen elsewhere and not reloaded yet: these times may be behind it.
        if let changedElsewhere { editor.entryChanged(revision: changedElsewhere.revision) }
        timingEditor = editor
    }

    /// "Save times": saved, the sheet closes and the entry shows its new times. Unsaved answer and
    /// notes edits stay on the form, now based on the saved revision.
    public func saveTiming() async {
        guard let editor = timingEditor, let saved = await editor.save() else { return }
        timingEditor = nil
        adopt(times: saved)
        _ = toasts.center.show(Toast("Times updated"))
    }

    /// The entry as the store shows it now (it changed: a sync, a save here or elsewhere). Its
    /// times and revision are taken as they are; an open Edit times sheet goes stale. When the
    /// answers, notes or source changed too: a clean form takes them, a dirty one keeps its
    /// edits and says so (``changedElsewhere``), with Reload.
    public func entryChanged(_ latest: Entry) {
        // An older revision (a pull behind a save here) never takes back what's newer.
        guard latest.id == entry.id, latest.revision >= entry.revision, !isFixing, !saved, !isDeleted else { return }
        timingEditor?.entryChanged(revision: latest.revision)
        let sameForm = latest.answers == entry.answers && latest.notes == entry.notes && latest.source == entry.source
        if sameForm {
            adopt(times: latest)
            return
        }
        if hasUnsavedChanges {
            changedElsewhere = latest
        } else {
            reload(latest)
        }
    }

    /// "Reload" on "This entry changed elsewhere": the form shows the entry as it is now, and the
    /// edits here are discarded.
    public func reloadChangedEntry() {
        guard let latest = changedElsewhere else { return }
        reload(latest)
    }

    private func reload(_ latest: Entry) {
        let fresh = FormModel(questions: form.questions, mode: .edit(answers: latest.answers))
        var latest = latest
        // Times saved here after `latest` was seen (an Edit times save) are newer: keep them, and
        // the revision the next save is based on.
        if latest.revision < entry.revision {
            latest.timing = entry.timing
            latest.capturedAt = entry.capturedAt
            latest.revision = entry.revision
        }
        entry = latest
        form = fresh
        baseline = fresh.inputs
        notes = latest.notes
        source = latest.source
        capturedAt = latest.capturedAt
        capturedAtEdited = false
        changedElsewhere = nil
        if !localOnly { baseRevision = latest.revision }
    }

    /// `latest`'s times, captured at and revision, keeping the form as it is.
    private func adopt(times latest: Entry) {
        let edited = capturedAtEdited
        entry.timing = latest.timing
        entry.capturedAt = latest.capturedAt
        entry.revision = latest.revision
        if isTimed || !edited {
            capturedAt = latest.capturedAt
            capturedAtEdited = edited && !isTimed
        }
        if !localOnly { baseRevision = latest.revision }
    }

    private func finish() -> Outcome {
        saved = true
        return .leave
    }

    /// The Details checks (`EntryMetaValidation`); opens Details on an error. True when fine.
    @discardableResult
    private func checkMeta() -> Bool {
        var errors: [EntryFormField: String] = [:]
        if capturedAtEdited, let issue = EntryMetaValidation.capturedAtIssue(capturedAt, limits: limits, now: now()) {
            errors[.capturedAt] = issue
        }
        if case .failure(let message) = EntryMetaValidation.notes(notes, limits: limits) {
            errors[.notes] = message.message
        }
        if case .failure(let message) = EntryMetaValidation.source(source, limits: limits) {
            errors[.source] = message.message
        }
        metaErrors = errors
        if !errors.isEmpty { showsDetails = true }
        return errors.isEmpty
    }
}

/// What the Details section (captured at, notes, source) edits: the record and edit screens.
@MainActor
public protocol EntryDetailsEditing: AnyObject, Observable {
    var capturedAt: Date { get set }
    var notes: String { get set }
    var source: String { get set }
    /// The record screen shows the device; the edit screen lets it be changed.
    var sourceIsEditable: Bool { get }
    var metaErrors: [EntryFormField: String] { get }
    var showsDetails: Bool { get set }
    /// A timed entry hides its captured at and source: they're its run's (timers.md §11.1).
    var showsCapturedAt: Bool { get }
    var showsSource: Bool { get }
}

extension EntryDetailsEditing {
    public var showsCapturedAt: Bool { true }
    public var showsSource: Bool { true }
}

extension RecordModel: EntryDetailsEditing {}

extension EntryPatch {
    /// This patch with `other`'s fields on top (answers merged by key).
    func overlaid(by other: EntryPatch) -> EntryPatch {
        var answers = self.answers ?? [:]
        for (key, value) in other.answers ?? [:] { answers[key] = .some(value) }
        return EntryPatch(
            answers: answers.isEmpty ? nil : answers, capturedAt: other.capturedAt ?? capturedAt,
            notes: other.notes ?? notes, source: other.source ?? source)
    }
}

extension Entry {
    /// The entry with `patch` applied, as the store's overlay applies an edit: answers merged by
    /// key (nil removes one), the rest replaced when set.
    func applying(_ patch: EntryPatch) -> Entry {
        var entry = self
        for (key, value) in patch.answers ?? [:] {
            if let value { entry.answers[key] = value } else { entry.answers.removeValue(forKey: key) }
        }
        if let capturedAt = patch.capturedAt { entry.capturedAt = capturedAt }
        if let notes = patch.notes { entry.notes = notes }
        if let source = patch.source { entry.source = source }
        return entry
    }
}
