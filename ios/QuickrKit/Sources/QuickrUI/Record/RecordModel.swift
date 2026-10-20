import Foundation
import Observation
import QuickrCore

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
///
/// Writes go through the app's `EntryFixing` writer and toasts through its `EntryToasts`, which
/// outlive this screen (an Undo tapped after it closes still works). Every write is pinned to its
/// store: a new entry's `LoggedEntry` carries the store it went to, and a fix acts in the store the
/// rejected item was read from; after a server switch or a reset they do nothing there.
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
    /// When it happened: the moment the form opened (or was reset by Log another), like the PWA,
    /// unless the user changes it.
    public var capturedAt: Date {
        didSet { capturedAtEdited = true }
    }
    public var notes = ""
    /// Shown, not edited (`sourceIsEditable` is false): the outbox sets it from the origin
    /// (outbox.md §4).
    public var source: String
    public var sourceIsEditable: Bool { false }
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
    /// A refusal with no `Problem` to put on the fields (either mode): shown over the form.
    public private(set) var rejectionMessage: String?

    @ObservationIgnored private let writer: any EntryFixing
    @ObservationIgnored private let toasts: EntryToasts
    /// The store the fix item was read from (fix mode).
    @ObservationIgnored private let fixScope: EntryScope?
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var baseline: [String: AnswerInput] = [:]
    @ObservationIgnored private var baselineNotes = ""
    @ObservationIgnored private var capturedAtEdited = false
    /// Saved and leaving: nothing to guard any more.
    @ObservationIgnored private var saved = false
    /// Fix mode's item as last read: its `rowVersion` changes with every fix.
    @ObservationIgnored private var currentFix: RecordFix?

    public init(
        topic: Topic, mode: Mode, writer: any EntryFixing, toasts: EntryToasts, scope: EntryScope? = nil,
        logAnother: Bool = false,
        source: String = "iOS app", limits: Limits = .serverDefaults, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.topic = topic
        self.mode = mode
        self.writer = writer
        self.toasts = toasts
        // The store the caller read the fix item from (taken with it); else the active one.
        fixScope = scope ?? writer.scope
        self.logAnother = logAnother
        self.source = source
        self.limits = limits
        self.now = now
        switch mode {
        case .new(let last):
            form = FormModel(questions: topic.questions, mode: .create(last: last))
            capturedAt = now()
        case .fix(let fix):
            currentFix = fix
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

    /// Puts text the user typed elsewhere into its fields and shows their validation: a reminder's
    /// number that didn't validate, brought back by its tap-to-fix notification
    /// (notifications.md §7.3). Keys the topic doesn't have are ignored.
    public func prefill(_ texts: [String: String]) {
        for (key, text) in texts.sorted(by: { $0.key < $1.key })
        where form.questions.contains(where: { $0.key == key }) {
            form.change(key, to: .text(text))
            form.focusChanged(key, isFocused: false)  // touched: the message shows
        }
    }

    /// Validates and saves. `.leave` when the screen should close. While it runs, `isSaving` is
    /// true: the view disables editing (so nothing typed meanwhile is lost) and a second Save is
    /// ignored.
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
        rejectionMessage = nil
        let notes = self.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.isEmpty ? nil : notes
        if let fix = currentFix { return await resubmit(fix, answers: answers, capturedAt: capturedAt, notes: note) }
        return await logNew(answers: answers, capturedAt: capturedAt, notes: note)
    }

    private func logNew(answers: [String: AnswerValue], capturedAt: Date, notes: String?) async -> Outcome {
        let entry: LoggedEntry
        do {
            entry = try await writer.log(EntryTopic(topic), answers: answers, capturedAt: capturedAt, notes: notes)
        } catch {
            toasts.logFailed(topicName: topic.name, writer.failure(error))
            return .stay
        }
        switch await writer.sendNow(entry, wait: Self.sendWait) {
        case .sent: toasts.recorded(entry, topicName: topic.name, sent: true)
        case .queued: toasts.recorded(entry, topicName: topic.name, sent: false)
        case .failed(let message, let problem):
            // A brand-new entry the user is still looking at: the errors go back on the form and
            // the queued copy goes (the PWA's recordEntry). In its own store only: after a switch
            // it stays there, for that store's sync sheet.
            try? await writer.discard(entry)
            show(problem, message: message)
            return .stay
        case .notSaved:
            toasts.logFailed(topicName: topic.name, .notSaved)
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
        guard let scope = fixScope else {
            toasts.logFailed(topicName: topic.name, .scopeChanged)
            return .stay
        }
        let entry: LoggedEntry
        do {
            entry = try await writer.fix(
                itemId: fix.itemId, rowVersion: fix.rowVersion, topic: EntryTopic(topic), answers: answers,
                capturedAt: capturedAt, notes: notes, in: scope)
        } catch {
            // Changed elsewhere (a CAS miss): pick up its version so the next save can apply.
            await refresh(fix)
            toasts.logFailed(topicName: topic.name, writer.failure(error))
            return .stay
        }
        switch await writer.sendNow(entry, wait: Self.sendWait) {
        case .sent: toasts.fixed(topicName: topic.name, sent: true)
        case .queued: toasts.fixed(topicName: topic.name, sent: false)
        case .failed(let message, let problem):
            // A fix keeps its item (discarding is the sync sheet's, explicitly). The fix moved its
            // row version: read it back so the user's next correction applies. Their answers stay.
            await refresh(fix)
            show(problem, message: message)
            return .stay
        case .notSaved:
            toasts.logFailed(topicName: topic.name, .notSaved)
        }
        return finish()
    }

    private func refresh(_ fix: RecordFix) async {
        guard let scope = fixScope, let version = try? await writer.rowVersion(itemId: fix.itemId, in: scope)
        else { return }
        currentFix?.rowVersion = version
    }

    /// The record screen's wait for `sendNow` (outbox.md §10).
    public static let sendWait: Duration = .seconds(8)

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
        rejectionMessage = nil
    }

    private func show(_ problem: Problem?, message: String) {
        if let problem {
            form.apply(problem)
            metaErrors = form.metaErrors
            if !metaErrors.isEmpty { showsDetails = true }
        } else {
            rejectionMessage = message
        }
    }

    /// The Details checks (`EntryMetaValidation`); opens Details on an error. True when fine.
    @discardableResult
    private func checkMeta() -> Bool {
        var errors: [EntryFormField: String] = [:]
        if let issue = EntryMetaValidation.capturedAtIssue(capturedAt, limits: limits, now: now()) {
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
