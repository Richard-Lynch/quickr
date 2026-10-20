import Foundation
import Observation
import QuickrCore

/// Edit a topic's questions into its next version (`/t/:ref/edit`, the PWA's
/// `EditQuestionsPage`). The draft starts from the current version with every question
/// published (`locked`): keys and types fixed, options archived rather than removed.
///
/// "Review changes" validates the draft, then asks the server for its compatibility report
/// against the version the editor started from (blocking issues light up their question's key).
/// The review shows the report and, when it allows publishing, a change note and "Publish
/// v(n+1)". Both calls are online only (sync-protocol.md §11): the server's 409 on a stale base
/// is seen live, and opens the conflict sheet: keep the draft (to copy from it), or load the
/// latest version, which starts over from it.
///
/// Editing is frozen while a call is out (``isBusy``; the screen disables the editor and the
/// sheets' other buttons), and every answer is checked against what it was asked about: a check
/// answered after the questions changed doesn't open the review; a publish that succeeds after
/// they changed keeps the later edits (and stays); "Keep my draft" makes a reload in flight drop
/// its answer.
@MainActor @Observable
public final class EditQuestionsModel: BuilderEditing {
    public static let clientInvalid = NewTopicModel.clientInvalid
    public static let leaveWarning = "Your question changes haven’t been published. Leave and lose them?"

    /// A report the server gave for the draft as it was then, and that draft's questions (what
    /// "Publish" sends).
    public struct Review: Sendable, Hashable {
        public var report: CompatibilityReport
        public var version: TopicDraft.Version
        /// The draft's questions it was checked for.
        public var questions: [DraftQuestion]
    }

    /// A check answered after the questions changed.
    public static let changedWhileChecking = "The questions changed while they were being checked. Review them again."
    /// A publish that succeeded after the questions changed: the reviewed ones were published.
    public static let changedWhilePublishing =
        "Your later edits weren’t published. They’re still here; load the latest version to start from it."

    /// The topic as it was when editing started (or was reloaded): the version edits are based on.
    public private(set) var base: Topic
    public var draft: TopicDraft {
        didSet { if submitted { revalidate() } }
    }
    public var expansion: QuestionExpansion
    public let preview = BuilderPreview()
    public private(set) var draftErrors: [DraftField: String] = [:]
    public private(set) var banner: String?
    public private(set) var bannerDetails: [String] = []
    /// The review sheet (``closeReview()`` closes it).
    public private(set) var review: Review?
    /// The change note's error, shown in the review (checked before publishing).
    public private(set) var noteError: String?
    /// The conflict sheet: someone published a newer version meanwhile.
    public var showsConflict = false
    public private(set) var isChecking = false
    public private(set) var isPublishing = false
    public private(set) var isReloading = false
    /// "Add an option…" text not added yet, by question.
    public var newOptionLabels: [DraftQuestion.ID: String] = [:]

    public let limits: Limits
    @ObservationIgnored private var initialDraft: TopicDraft
    @ObservationIgnored private var submitted = false
    @ObservationIgnored private var published = false
    /// The reload whose answer is still wanted ("Keep my draft" drops it).
    @ObservationIgnored private var reload: UUID?
    @ObservationIgnored private let writer: any VersionWriter
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let onPublished: @MainActor (Topic) -> Void

    public init(
        topic: Topic, writer: any VersionWriter, toasts: ToastCenter, limits: Limits = .serverDefaults,
        onPublished: @escaping @MainActor (Topic) -> Void = { _ in }
    ) {
        let draft = Self.draft(for: topic)
        base = topic
        self.draft = draft
        initialDraft = draft
        expansion = QuestionExpansion(.none, questions: draft.questions)
        self.writer = writer
        self.toasts = toasts
        self.limits = limits
        self.onPublished = onPublished
    }

    private static func draft(for topic: Topic) -> TopicDraft {
        TopicDraft.editing(
            name: topic.name, slug: topic.slug, description: topic.description, questions: topic.questions)
    }

    /// The version publishing creates.
    public var nextVersion: Int { base.currentVersion + 1 }

    /// Leaving asks first once anything was edited (an option still being typed included), until
    /// it is published.
    public var hasUnsavedChanges: Bool {
        !published && (draft != initialDraft || hasPendingOptionText)
    }

    /// A call is out: the editor and the sheets' other buttons wait for it.
    public var isBusy: Bool { isChecking || isPublishing || isReloading }

    /// Like the create form's: "Fix the highlighted fields" only while a field still shows an error.
    public var visibleBanner: String? {
        guard let banner else { return nil }
        if banner == Self.clientInvalid && draftErrors.isEmpty { return nil }
        return banner
    }

    /// A question's label for the report: the draft's, else the base version's, else its key.
    public func label(forKey key: String) -> String {
        if let label = draft.questions.first(where: { $0.key == key })?.label, !label.isEmpty { return label }
        if let label = base.questions.first(where: { $0.key == key })?.label, !label.isEmpty { return label }
        return key
    }

    @discardableResult
    private func revalidate() -> TopicDraft.Version? {
        switch draft.validatedQuestions(limits: limits) {
        case .success(let questions):
            draftErrors = [:]
            return TopicDraft.Version(questions: questions, changeNote: draft.changeNote)
        case .failure(let issues):
            draftErrors = issues.byField
            return nil
        }
    }

    /// "Review changes".
    public func reviewChanges() async {
        guard !isBusy else { return }
        submitted = true
        banner = nil
        bannerDetails = []
        guard let version = revalidate() else {
            banner = Self.clientInvalid
            return
        }
        isChecking = true
        defer { isChecking = false }
        let questions = draft.questions
        let outcome = await writer.checkVersion(version, baseVersion: base.currentVersion, topicId: base.id)
        // The answer is about the questions as they were: if they changed, it isn't theirs.
        guard draft.questions == questions else {
            banner = Self.changedWhileChecking
            return
        }
        guard case .done(let report) = outcome else { return failed(outcome) }
        // Light up the questions with blocking issues.
        draftErrors.merge(BuilderProblemMapping.blockingFields(report, draft: draft)) { _, new in new }
        noteError = nil
        review = Review(report: report, version: version, questions: questions)
    }

    /// "Publish v(n+1)" in the review.
    public func publish() async {
        guard let review, review.report.ok, !isPublishing else { return }
        let note = JSNumber.trim(draft.changeNote)
        if BuilderText.count(note) > limits.maxChangeNoteLength {
            noteError = "At most \(limits.maxChangeNoteLength) characters"
            return
        }
        noteError = nil
        isPublishing = true
        defer { isPublishing = false }
        let outcome = await writer.publishVersion(
            review.version, baseVersion: base.currentVersion, changeNote: note, topicId: base.id)
        guard case .done(let topic) = outcome else { return failed(outcome) }
        self.review = nil
        toasts.show(Toast("Published v\(topic.currentVersion)"))
        // Edits made meanwhile weren't in it: keep them, and stay.
        guard draft.questions == review.questions else {
            banner = Self.changedWhilePublishing
            return
        }
        published = true
        onPublished(topic)
    }

    /// "Keep editing": closes the review, except while it is publishing.
    public func closeReview() {
        guard !isPublishing else { return }
        review = nil
    }

    /// A refused check or publish: a newer version opens the conflict sheet; anything else closes
    /// the review and shows the server's errors on the fields and in the banner.
    private func failed<Value>(_ outcome: TopicWriteOutcome<Value>) {
        review = nil
        if case .rejected(let problem?) = outcome, problem.code == .conflict {
            showsConflict = true
            return
        }
        if case .rejected(let problem?) = outcome {
            let mapped = BuilderProblemMapping.builderForm(problem, draft: draft)
            draftErrors.merge(mapped.fields) { _, new in new }
            banner = mapped.banner
            bannerDetails = mapped.unplaced.map(\.message)
        } else {
            banner = outcome.message ?? "The server refused the new version."
        }
    }

    /// "Keep my draft": close the conflict sheet; the draft stays as it is (publishing it will
    /// conflict again until the latest version is loaded).
    /// A reload in flight is dropped: its answer won't replace the draft.
    public func keepDraft() {
        reload = nil
        isReloading = false
        showsConflict = false
    }

    /// "Load latest version": fetch the topic and start over from its current version. The
    /// unsaved edits are discarded.
    public func reloadLatest() async {
        guard !isReloading else { return }
        let token = UUID()
        reload = token
        isReloading = true
        let outcome = await writer.latestTopic(topicId: base.id)
        // "Keep my draft" meanwhile: the answer isn't wanted any more.
        guard reload == token else { return }
        reload = nil
        isReloading = false
        guard case .done(let fresh) = outcome else {
            let message: String? =
                if case .rejected(let problem?) = outcome { ProblemMapping.banner(for: problem) } else {
                    outcome.message
                }
            toasts.show(Toast("Could not reload", message: message, tone: .danger))
            return
        }
        showsConflict = false
        rebase(on: fresh)
        toasts.show(
            Toast("Loaded v\(fresh.currentVersion)", message: "Your unsaved edits were discarded.", tone: .info))
    }

    private func rebase(on topic: Topic) {
        base = topic
        submitted = false
        let draft = Self.draft(for: topic)
        self.draft = draft
        initialDraft = draft
        expansion = QuestionExpansion(.none, questions: draft.questions)
        draftErrors = [:]
        banner = nil
        bannerDetails = []
        review = nil
        noteError = nil
        newOptionLabels = [:]
        preview.reset()
    }
}

/// The review's text (`CompatReport`).
public enum CompatReportText {
    /// The banner over the report.
    public static func headline(_ report: CompatibilityReport) -> String {
        report.ok ? "Ready to publish as v\(report.nextVersion)" : "Can’t publish yet — fix the errors below"
    }

    /// Errors first, then warnings, then notes, each in the server's order.
    public static func sortedIssues(_ report: CompatibilityReport) -> [CompatibilityReport.Issue] {
        let rank: [CompatibilityReport.Level: Int] = [.error: 0, .warning: 1, .info: 2]
        return report.issues.enumerated()
            .sorted { (rank[$0.element.level]!, $0.offset) < (rank[$1.element.level]!, $1.offset) }
            .map(\.element)
    }

    public static func levelLabel(_ level: CompatibilityReport.Level) -> String {
        switch level {
        case .error: "Blocks publishing"
        case .warning: "Warning"
        case .info: "Info"
        }
    }

    public static func kindLabel(_ kind: CompatibilityReport.ChangeKind) -> String {
        switch kind {
        case .added: "added"
        case .removed: "removed"
        case .modified: "changed"
        case .restored: "restored"
        case .reordered: "reordered"
        }
    }

    /// A change's subject: its question's label, or "Question order" for a reorder (`*`).
    public static func subject(_ change: CompatibilityReport.Change, label: (String) -> String) -> String {
        change.questionKey == "*" ? "Question order" : label(change.questionKey)
    }
}
