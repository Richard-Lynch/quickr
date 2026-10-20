import Foundation
import Observation
import QuickrCore

/// The changed fields of an edit: answers by key (nil clears one), captured at, notes. Only what
/// changed is set (outbox.md §1: an `entry.update` holds only the changed keys).
public struct EntryPatch: Sendable, Hashable {
    public var answers: [String: AnswerValue?]?
    public var capturedAt: Date?
    public var notes: String?

    public init(answers: [String: AnswerValue?]? = nil, capturedAt: Date? = nil, notes: String? = nil) {
        self.answers = answers
        self.capturedAt = capturedAt
        self.notes = notes
    }

    public var isEmpty: Bool { answers == nil && capturedAt == nil && notes == nil }
}

/// What the edit screen writes through: an update, pinned to the store the entry was read from.
@MainActor
public protocol EntryEditing: AnyObject {
    /// Queues the edit (outbox.md §7.3: `baseRevision` is the server revision the user edited,
    /// nil for an entry the server doesn't have yet). Throws the outbox's errors, or
    /// `EntryWriteError.scopeChanged` once `scope` isn't the active store.
    func update(entryId: UUID, topicId: UUID, patch: EntryPatch, baseRevision: Int?, in scope: EntryScope)
        async throws
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
    /// The entry as the screen opened it (the store's view of it: queued edits applied).
    public let entry: Entry
    public private(set) var form: FormModel
    public var capturedAt: Date {
        didSet { capturedAtEdited = true }
    }
    public var notes: String
    /// Shown, not edited.
    public let source: String
    public private(set) var metaErrors: [EntryFormField: String] = [:]
    public var showsDetails = false
    public private(set) var isSaving = false
    /// The entry was deleted (here, elsewhere, or by a sync): nothing to save any more.
    public private(set) var isDeleted = false
    /// Why the last save didn't go through.
    public private(set) var errorMessage: String?
    /// Why the entry's last change didn't sync (shown over the form), if it didn't.
    public let syncProblem: String?

    @ObservationIgnored private let writer: any EntryEditing
    @ObservationIgnored private let toasts: EntryToasts
    @ObservationIgnored private let scope: EntryScope
    @ObservationIgnored private let baseRevision: Int?
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let baseline: [String: AnswerInput]
    @ObservationIgnored private var capturedAtEdited = false
    @ObservationIgnored private var saved = false

    /// - Parameters:
    ///   - questions: the questions of the entry's own version.
    ///   - localOnly: the server doesn't have the entry yet (its create is queued).
    ///   - scope: the store the entry was read from.
    public init(
        topic: Topic, entry: Entry, questions: [Question], localOnly: Bool, syncProblem: String? = nil,
        writer: any EntryEditing, toasts: EntryToasts, scope: EntryScope, limits: Limits = .serverDefaults,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.topic = topic
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
        capturedAtEdited = false
    }

    /// Logged with an older version than the topic's current one: validated with that version's
    /// questions, so historic answers stay consistent.
    public var isOutdated: Bool { entry.version != topic.currentVersion }

    public var hasUnsavedChanges: Bool {
        !saved && !isDeleted && (form.inputs != baseline || notes != entry.notes || capturedAtEdited)
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
        let patch = changes(answers)
        guard !patch.isEmpty else { return finish() }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
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
    /// if changed.
    func changes(_ answers: [String: AnswerValue?]) -> EntryPatch {
        var changed: [String: AnswerValue?] = [:]
        for (key, value) in answers where value != entry.answers[key] {
            changed[key] = .some(value)
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return EntryPatch(
            answers: changed.isEmpty ? nil : changed,
            capturedAt: capturedAtEdited && capturedAt != entry.capturedAt ? capturedAt : nil,
            notes: trimmed != entry.notes ? trimmed : nil)
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
    var source: String { get }
    var metaErrors: [EntryFormField: String] { get }
    var showsDetails: Bool { get set }
}

extension RecordModel: EntryDetailsEditing {}
