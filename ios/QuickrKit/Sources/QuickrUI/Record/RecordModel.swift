import Foundation
import Observation
import QuickrCore

/// What the record screen writes through: `AppSession` in the app, a fake in tests.
@MainActor
public protocol RecordWriter: AnyObject {
    /// Enqueues a new entry durably; returns its id (also its outbox item's).
    func log(
        _ topic: Topic, answers: [String: AnswerValue], capturedAt: Date, notes: String?
    ) async throws -> UUID
    /// Sends the entry now and waits a little (8 s, outbox.md §10) for the outcome.
    func sendNow(_ entryId: UUID) async -> RecordDelivery
    /// Drops a rejected new entry from the queue (the form keeps the user's answers).
    func discard(_ entryId: UUID) async
    /// Fix mode: replaces the rejected item's body and queues it again.
    func fix(
        _ fix: RecordFix, topic: Topic, answers: [String: AnswerValue], capturedAt: Date, notes: String?
    ) async throws
    /// What to say about a refused write.
    func failure(_ error: any Error) -> RecordFailure
}

/// What `sendNow` saw.
public enum RecordDelivery: Sendable, Hashable {
    case sent
    /// Saved on this device; it syncs later.
    case queued
    /// The server refused it: the `Problem` goes on the form (nil: only `message` is known).
    case rejected(Problem?, message: String)
    /// The entry was deleted meanwhile and will never be recorded.
    case notSaved
}

public enum RecordFailure: Sendable, Hashable {
    /// The entry was deleted (it won't be recorded).
    case notSaved
    case message(String)
}

/// The toasts the record screen raises (the app's `EntryToasts`; a fake in tests).
@MainActor
public protocol RecordNotices: AnyObject {
    /// "Logged …" or "Saved on this device", with Undo.
    func logged(entryId: UUID, topic: Topic, sent: Bool)
    /// A fixed entry went out again (no Undo: it is the user's correction).
    func fixed(topic: Topic, sent: Bool)
    func failed(topic: Topic, _ failure: RecordFailure)
}

/// A rejected entry to fix (from the sync sheet or a `?fix=` link).
public struct RecordFix: Sendable, Hashable {
    public var itemId: String
    public var rowVersion: Int
    public var answers: [String: AnswerValue]
    public var capturedAt: Date?
    public var notes: String?
    public var problem: Problem?
    /// The failure's message when there's no `Problem` to place.
    public var message: String?

    public init(
        itemId: String, rowVersion: Int, answers: [String: AnswerValue], capturedAt: Date?, notes: String?,
        problem: Problem?, message: String?
    ) {
        self.itemId = itemId
        self.rowVersion = rowVersion
        self.answers = answers
        self.capturedAt = capturedAt
        self.notes = notes
        self.problem = problem
        self.message = message
    }
}

/// The record screen (the PWA's `RecordPage` with `EntryForm`): the answers (`FormModel`), the
/// Details (captured at, notes, source), Save with its busy state, "Log another", the single-chip
/// auto-save, fix mode, and whether leaving would lose changes.
///
/// A new entry is enqueued, then sent at once with a short wait: sent or queued, it toasts with
/// Undo and the screen closes (or, with Log another, starts a fresh form); rejected, the queued
/// copy is dropped and the server's errors land on the fields. A fix replaces the rejected item's
/// body; rejected again, it keeps the item and shows the errors.
@MainActor @Observable
public final class RecordModel {
    public enum Mode: Sendable, Hashable {
        case new(last: LastEntry?)
        case fix(RecordFix)
    }

    /// After a save: stay (errors, or Log another), or close the screen.
    public enum Outcome: Sendable, Hashable {
        case stay
        case leave
    }

    public let topic: Topic
    public let mode: Mode
    public private(set) var form: FormModel
    /// When it happened. Untouched, a new entry takes the moment of Save.
    public var capturedAt: Date {
        didSet { capturedAtEdited = true }
    }
    public var notes = ""
    /// Shown, not edited: the outbox sets it from the origin (outbox.md §4).
    public let source: String
    /// Errors on `captured_at`, `source` and `notes`: local checks and the server's (fix mode).
    public private(set) var metaErrors: [EntryFormField: String] = [:]
    /// The Details section is open (the user's, or forced by an error in it).
    public var showsDetails = false
    /// Stay on the screen after saving, with a fresh form (remembered by the caller).
    public var logAnother: Bool
    public private(set) var isSaving = false
    /// Entries logged on this screen with Log another (the PWA's "+N").
    public private(set) var loggedCount = 0
    /// A banner for a fix whose failure had no `Problem` to place.
    public private(set) var fixMessage: String?

    @ObservationIgnored private let writer: any RecordWriter
    @ObservationIgnored private let notices: any RecordNotices
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var baseline: [String: AnswerInput] = [:]
    @ObservationIgnored private var baselineNotes = ""
    @ObservationIgnored private var capturedAtEdited = false
    /// Saved and leaving: nothing to guard any more.
    @ObservationIgnored private var saved = false

    public init(
        topic: Topic, mode: Mode, writer: any RecordWriter, notices: any RecordNotices, logAnother: Bool = false,
        source: String = "iOS app", limits: Limits = .serverDefaults, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.topic = topic
        self.mode = mode
        self.writer = writer
        self.notices = notices
        self.logAnother = logAnother
        self.source = source
        self.limits = limits
        self.now = now
        switch mode {
        case .new(let last):
            form = FormModel(questions: topic.questions, mode: .create(last: last))
            capturedAt = now()
        case .fix(let fix):
            form = FormModel(questions: topic.questions, mode: .fix(answers: fix.answers, problem: fix.problem))
            capturedAt = fix.capturedAt ?? now()
            notes = fix.notes ?? ""
            baselineNotes = notes
            fixMessage = fix.problem == nil ? fix.message : nil
        }
        baseline = form.inputs
        capturedAtEdited = false
        metaErrors = form.metaErrors
        showsDetails = !metaErrors.isEmpty
    }

    public var isFixing: Bool {
        if case .fix = mode { return true }
        return false
    }

    /// Whether leaving now would lose what the user typed.
    public var hasUnsavedChanges: Bool {
        !saved && (form.inputs != baseline || notes != baselineNotes || capturedAtEdited)
    }

    /// Validates and saves. `.leave` when the screen should close.
    public func save() async -> Outcome {
        guard !isSaving else { return .stay }
        guard let body = form.submit() else {
            checkMeta()
            return .stay
        }
        return await save(body)
    }

    /// `FormView`'s `onAutoSave` (a single-chip topic's pick): true when it was saved or queued.
    /// The caller closes the screen then.
    public func autoSave(_ body: AnswersBody) async -> Bool {
        await save(body) == .leave
    }

    private func save(_ body: AnswersBody) async -> Outcome {
        guard !isSaving, checkMeta(), case .create(let answers) = body else { return .stay }
        isSaving = true
        defer { isSaving = false }
        let when = capturedAtEdited || isFixing ? capturedAt : now()
        let notes = self.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.isEmpty ? nil : notes
        switch mode {
        case .new: return await logNew(answers: answers, capturedAt: when, notes: note)
        case .fix(let fix): return await resubmit(fix, answers: answers, capturedAt: when, notes: note)
        }
    }

    private func logNew(answers: [String: AnswerValue], capturedAt: Date, notes: String?) async -> Outcome {
        let id: UUID
        do {
            id = try await writer.log(topic, answers: answers, capturedAt: capturedAt, notes: notes)
        } catch {
            notices.failed(topic: topic, writer.failure(error))
            return .stay
        }
        switch await writer.sendNow(id) {
        case .sent: notices.logged(entryId: id, topic: topic, sent: true)
        case .queued: notices.logged(entryId: id, topic: topic, sent: false)
        case .rejected(let problem, let message):
            // A brand-new entry the user is still looking at: the errors go back on the form and
            // the queued copy goes (the PWA's recordEntry).
            await writer.discard(id)
            show(problem, message: message)
            return .stay
        case .notSaved:
            notices.failed(topic: topic, .notSaved)
            return finish()
        }
        guard logAnother else { return finish() }
        loggedCount += 1
        startAnother(last: LastEntry(answers: answers, capturedAt: capturedAt))
        return .stay
    }

    private func resubmit(
        _ fix: RecordFix, answers: [String: AnswerValue], capturedAt: Date, notes: String?
    ) async -> Outcome {
        do {
            try await writer.fix(fix, topic: topic, answers: answers, capturedAt: capturedAt, notes: notes)
        } catch {
            notices.failed(topic: topic, writer.failure(error))
            return .stay
        }
        switch await writer.sendNow(UUID(uuidString: fix.itemId) ?? UUID()) {
        case .sent: notices.fixed(topic: topic, sent: true)
        case .queued: notices.fixed(topic: topic, sent: false)
        case .rejected(let problem, let message):
            // A fix keeps its item (discarding is the sync sheet's, explicitly).
            show(problem, message: message)
            return .stay
        case .notSaved:
            notices.failed(topic: topic, .notSaved)
        }
        return finish()
    }

    private func finish() -> Outcome {
        saved = true
        return .leave
    }

    /// Log another: a fresh form whose "Same as last time" is the entry just logged.
    private func startAnother(last: LastEntry) {
        form = FormModel(questions: topic.questions, mode: .create(last: last))
        baseline = form.inputs
        notes = ""
        baselineNotes = ""
        capturedAt = now()
        capturedAtEdited = false
        metaErrors = [:]
        fixMessage = nil
    }

    private func show(_ problem: Problem?, message: String) {
        if let problem {
            form.apply(problem)
            metaErrors = form.metaErrors
            if !metaErrors.isEmpty { showsDetails = true }
        } else {
            fixMessage = message
        }
    }

    /// The Details checks (`EntryMetaValidation`); opens Details on an error. True when fine.
    @discardableResult
    private func checkMeta() -> Bool {
        var errors: [EntryFormField: String] = [:]
        if capturedAtEdited || isFixing,
            let issue = EntryMetaValidation.capturedAtIssue(capturedAt, limits: limits, now: now())
        {
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
