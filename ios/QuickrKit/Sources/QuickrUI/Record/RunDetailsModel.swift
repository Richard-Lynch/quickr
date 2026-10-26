import Foundation
import Observation
import QuickrCore

/// What sending a run's answers came to (`RunFinishing`).
public enum RunFinishDelivery: Sendable, Hashable {
    /// The server has them.
    case sent
    /// Kept on the device; they sync later.
    case queued
    /// Refused: the errors go back on the form. A new finish's item was dropped; a fix keeps its
    /// item.
    case failed(message: String, problem: Problem?)
    /// The run is still open on the server (409 `run_open`, §3.6): its stop isn't in yet. The
    /// item was dropped and the typed answers stay on the form to send again.
    case runOpen
    /// Nothing was enqueued (the run and its entry are gone here, or the store changed).
    case notSaved(String)
}

/// Sends a run's answers as `finish` (timers.md §3.6) and waits briefly for the server, like the
/// record screen. The app's is `SessionRunFinisher`.
public protocol RunFinishing: Sendable {
    func finish(runId: String, answers: [String: AnswerValue], notes: String?) async -> RunFinishDelivery
    /// Replaces a refused finish's answers and notes and sends it again (the sync sheet's Fix).
    /// Refused again, the item stays for the sync sheet.
    func refix(itemId: String, answers: [String: AnswerValue], notes: String?) async -> RunFinishDelivery
}

/// A refused finish to fix (the sync sheet's Fix): its item, answers and the server's errors.
public struct RunDetailsFix: Sendable, Hashable {
    public var itemId: String
    public var answers: [String: AnswerValue]
    public var notes: String?
    public var problem: Problem?
    public var message: String?

    public init(
        itemId: String, answers: [String: AnswerValue], notes: String?, problem: Problem?, message: String?
    ) {
        self.itemId = itemId
        self.answers = answers
        self.notes = notes
        self.problem = problem
        self.message = message
    }
}

/// The answers form of a run that Stop ended (timers.md §11.2, the PWA's `RunDetailsForm`): the
/// questions of the run's own version, and notes. `captured_at` and source aren't shown (a timed
/// entry's time is its run's, §11.1), and there is no Discard: the run is stopped. Save sends
/// `finish`. Leaving without saving keeps a finishing run as "Add details" on home.
@MainActor @Observable
public final class RunDetailsModel {
    public enum Outcome: Sendable, Hashable {
        case stay
        case leave
    }

    public let topicName: String
    public let runId: String
    public let fix: RunDetailsFix?
    public let form: FormModel
    public var notes: String
    public private(set) var isSaving = false
    /// A refusal the fields can't show, or the run still being open: shown over the form.
    public private(set) var banner: String?
    /// Saved, or queued: the toast after leaving.
    public private(set) var savedMessage: String?

    @ObservationIgnored private let finisher: any RunFinishing
    @ObservationIgnored private let baselineNotes: String
    @ObservationIgnored private let baselineInputs: [String: AnswerInput]
    @ObservationIgnored private var saved = false

    /// - Parameter questions: the run's own version's questions (never the topic's current ones).
    public init(
        topicName: String, runId: String, questions: [Question], fix: RunDetailsFix? = nil,
        finisher: any RunFinishing
    ) {
        self.topicName = topicName
        self.runId = runId
        self.fix = fix
        self.finisher = finisher
        let form: FormModel
        if let fix {
            form = FormModel(questions: questions, mode: .fix(answers: fix.answers, problem: fix.problem))
        } else {
            // Fix mode's rules without a problem: no "Same as last time" and no single-chip
            // auto-save, so notes can be added before Save.
            form = FormModel(questions: questions, mode: .fix(answers: [:], problem: nil))
        }
        self.form = form
        notes = fix?.notes ?? ""
        baselineNotes = fix?.notes ?? ""
        baselineInputs = form.inputs
        banner = fix?.problem == nil ? fix?.message : nil
    }

    public var isFixing: Bool { fix != nil }

    /// Whether leaving now would lose what the user typed.
    public var hasUnsavedChanges: Bool { !saved && (form.inputs != baselineInputs || notes != baselineNotes) }

    /// Validates and sends the answers. `.leave` once they are sent or queued.
    public func save() async -> Outcome {
        guard !isSaving else { return .stay }
        guard let body = form.submit(), case .create(let answers) = body else { return .stay }
        isSaving = true
        defer { isSaving = false }
        banner = nil
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmed.isEmpty ? nil : trimmed
        let delivery: RunFinishDelivery
        if let fix {
            delivery = await finisher.refix(itemId: fix.itemId, answers: answers, notes: note)
        } else {
            delivery = await finisher.finish(runId: runId, answers: answers, notes: note)
        }
        switch delivery {
        case .sent:
            savedMessage = "Saved \(topicName)"
        case .queued:
            savedMessage = "Saved \(topicName) on this device"
        case .failed(let message, let problem):
            if let problem { form.apply(problem) } else { banner = "The server said: \(message)" }
            return .stay
        case .runOpen:
            banner = "\(topicName) hasn’t stopped on the server yet. Your answers are kept: save again in a moment."
            return .stay
        case .notSaved(let message):
            banner = message
            return .stay
        }
        saved = true
        return .leave
    }
}
