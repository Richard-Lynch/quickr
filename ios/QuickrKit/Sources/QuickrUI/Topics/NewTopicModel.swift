import Foundation
import Observation
import QuickrCore

/// Create a topic (`/new`, the PWA's `NewTopicPage`): name, slug and description, the questions
/// (BUILDER's `TopicDraft`, in the builder's cards and preview), an optional schedule, then
/// "Create topic". Online only. On success it
/// opens the new topic's record screen ("Topic created · Log your first entry.").
@MainActor @Observable
public final class NewTopicModel: BuilderEditing {
    public static let clientInvalid = "Fix the highlighted fields"
    public static let leaveWarning = "This topic hasn’t been created yet. Leave and lose it?"

    public var draft: TopicDraft {
        didSet { if submitted { revalidate() } }
    }
    public var schedule: ScheduleDraft {
        didSet { if submitted { revalidate() } }
    }
    /// Every card starts open (`defaultExpanded="all"`).
    public var expansion: QuestionExpansion
    public let preview = BuilderPreview()
    /// "Add an option…" text not added yet, by question.
    public var newOptionLabels: [DraftQuestion.ID: String] = [:]
    public private(set) var draftErrors: [DraftField: String] = [:]
    public private(set) var scheduleErrors: [ScheduleField: String] = [:]
    /// The banner over the form, and the issues no field shows (listed under it).
    public private(set) var banner: String?
    public private(set) var bannerDetails: [String] = []
    public private(set) var isCreating = false
    /// Counts "Create topic" taps: a repeated identical banner is announced again (`qrAnnouncesError`).
    public private(set) var attempts = 0
    /// After the first Create, edits revalidate as they happen (`reValidateMode: 'onChange'`).
    private var submitted = false

    public let limits: Limits
    /// A new topic has no versions, so no step key is taken yet.
    public var stepHistory: [HistoricStep] { [] }
    @ObservationIgnored private let initialDraft: TopicDraft
    @ObservationIgnored private let initialSchedule: ScheduleDraft
    @ObservationIgnored private let writer: any TopicWriter
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let isKnownTimeZone: (String) -> Bool
    @ObservationIgnored private let onCreated: @MainActor (Topic) -> Void

    public init(
        writer: any TopicWriter, toasts: ToastCenter, limits: Limits = .serverDefaults,
        deviceTimeZone: String = TimeZone.current.identifier,
        isKnownTimeZone: @escaping (String) -> Bool = ScheduleDraft.isKnownTimeZone,
        onCreated: @escaping @MainActor (Topic) -> Void = { _ in }
    ) {
        let draft = TopicDraft.empty()
        let schedule = ScheduleDraft.empty(timezone: deviceTimeZone)
        self.draft = draft
        self.schedule = schedule
        expansion = QuestionExpansion(.all, questions: draft.questions)
        initialDraft = draft
        initialSchedule = schedule
        self.writer = writer
        self.toasts = toasts
        self.limits = limits
        self.isKnownTimeZone = isKnownTimeZone
        self.onCreated = onCreated
    }

    /// Leaving asks first once anything was edited.
    public var hasUnsavedChanges: Bool {
        draft != initialDraft || schedule != initialSchedule || hasPendingOptionText
    }

    /// The banner shows a server error always, and "Fix the highlighted fields" only while some
    /// field still shows an error.
    public var visibleBanner: String? {
        guard let banner else { return nil }
        if banner == Self.clientInvalid && draftErrors.isEmpty && scheduleErrors.isEmpty { return nil }
        return banner
    }

    public var schedulePreview: String { schedule.preview(limits: limits, isKnownTimeZone: isKnownTimeZone) }

    private struct Valid {
        var creation: TopicDraft.Creation
        var schedule: Schedule?
    }

    /// Validates everything, setting each field's message; nil when something is wrong.
    @discardableResult
    private func revalidate() -> Valid? {
        let creation = draft.validatedForCreation(limits: limits)
        let schedule = schedule.validated(limits: limits, isKnownTimeZone: isKnownTimeZone)
        switch creation {
        case .success: draftErrors = [:]
        case .failure(let issues): draftErrors = issues.byField
        }
        scheduleErrors = schedule.failureIssues
        guard case .success(let valid) = creation, case .success(let value) = schedule else { return nil }
        return Valid(creation: valid, schedule: value)
    }

    /// "Create topic".
    public func create() async {
        guard !isCreating else { return }
        attempts += 1
        submitted = true
        banner = nil
        bannerDetails = []
        guard let valid = revalidate() else {
            banner = Self.clientInvalid
            return
        }
        isCreating = true
        defer { isCreating = false }
        let outcome = await writer.create(valid.creation, schedule: valid.schedule)
        switch outcome {
        case .done(let topic):
            toasts.show(Toast("Topic created", message: "Log your first entry."))
            onCreated(topic)
        case .rejected(let problem?):
            place(problem)
        default:
            banner = outcome.message ?? "The server refused the topic."
        }
    }

    /// The server's errors on the builder's fields and the schedule's (`builderFieldFor`); the
    /// rest under the banner.
    private func place(_ problem: Problem) {
        let mapped = BuilderProblemMapping.builderForm(problem, draft: draft)
        draftErrors.merge(mapped.fields) { _, new in new }
        var unplaced: [String] = []
        for issue in mapped.unplaced {
            let path = ProblemMapping.path(issue.location)
            guard path == "schedule" || path.hasPrefix("schedule."), var field = ScheduleField(serverPath: path)
            else {
                unplaced.append(issue.message)
                continue
            }
            // A time the draft doesn't have lights up the list.
            if case .time(let i) = field, !schedule.times.indices.contains(i) { field = .times }
            scheduleErrors[field] = issue.message
        }
        banner = mapped.banner
        bannerDetails = unplaced
    }
}

extension QuestionType {
    /// The builder's names for each type (`TYPE_META`).
    public var builderLabel: String {
        switch self {
        case .int: "Whole number"
        case .double: "Decimal number"
        case .str: "Text"
        case .enum: "Choice"
        }
    }

    /// The type chip's text (`TYPE_META.short`).
    public var builderShort: String {
        switch self {
        case .int: "Int"
        case .double: "Dec"
        case .str: "Text"
        case .enum: "Pick"
        }
    }

    /// The question field's placeholder for a new question (`placeholderFor`).
    public var builderPlaceholder: String {
        switch self {
        case .int: "e.g. Glasses of water"
        case .double: "e.g. Hours slept"
        case .str: "e.g. What went well?"
        case .enum: "e.g. How do you feel?"
        }
    }

    public var builderHint: String {
        switch self {
        case .int: "Counts, steps, ratings 1–10"
        case .double: "Weights, hours, temperatures"
        case .str: "Notes, names, free answers"
        case .enum: "One or several options from a list"
        }
    }
}
