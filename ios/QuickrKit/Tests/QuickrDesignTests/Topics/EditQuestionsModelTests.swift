import Foundation
import QuickrCore
import QuickrUI
import Testing

/// Holds a call until opened, so a test can act while it is out (an answer arriving late).
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Waits (bounded: 2 s) until `condition` holds; records an issue if it never does.
@MainActor
func eventually(_ what: String, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("never: \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A `VersionWriter` that answers like the server, or with a set outcome.
@MainActor
final class FakeVersionWriter: VersionWriter {
    enum Call: Equatable {
        case check(keys: [String], base: Int)
        case publish(keys: [String], base: Int, note: String)
        case latest
    }

    var calls: [Call] = []
    /// Every checked or published version, in order.
    var versions: [TopicDraft.Version] = []
    var report: CompatibilityReport
    var checkResult: TopicWriteOutcome<CompatibilityReport>?
    var publishResult: TopicWriteOutcome<Topic>?
    var latestResult: TopicWriteOutcome<Topic>?
    /// Hold each call (after recording it) until the gate opens.
    var checkGate: Gate?
    var publishGate: Gate?
    var latestGate: Gate?
    /// The server's topic.
    var server: Topic

    init(server: Topic, report: CompatibilityReport) {
        self.server = server
        self.report = report
    }

    func checkVersion(_ version: TopicDraft.Version, baseVersion: Int, topicId: UUID) async
        -> TopicWriteOutcome<CompatibilityReport>
    {
        calls.append(.check(keys: version.questions.map(\.key), base: baseVersion))
        versions.append(version)
        await checkGate?.wait()
        return checkResult ?? .done(report)
    }

    func publishVersion(_ version: TopicDraft.Version, baseVersion: Int, changeNote: String, topicId: UUID) async
        -> TopicWriteOutcome<Topic>
    {
        calls.append(.publish(keys: version.questions.map(\.key), base: baseVersion, note: changeNote))
        versions.append(version)
        await publishGate?.wait()
        if let publishResult { return publishResult }
        server.currentVersion += 1
        server.questions = version.questions
        server.timer = version.timer
        return .done(server)
    }

    /// The server's versions ("Load latest version" reads their step keys).
    var versionsResult: TopicWriteOutcome<[TopicVersion]> = .offline

    func versions(topicId: UUID) async -> TopicWriteOutcome<[TopicVersion]> { versionsResult }

    func latestTopic(topicId: UUID) async -> TopicWriteOutcome<Topic> {
        calls.append(.latest)
        await latestGate?.wait()
        return latestResult ?? .done(server)
    }
}

@MainActor @Suite struct EditQuestionsModelTests {
    static let questions = [
        Question(key: "mood", label: "Mood", kind: .int(.init(min: 1, max: 5))),
        Question(
            key: "where", label: "Where",
            kind: .choice(.init(options: [.init(value: "home", label: "Home"), .init(value: "work", label: "Work")]))),
    ]
    static let topic = Topic(
        id: UUID(), slug: "mood", name: "Mood", description: "", currentVersion: 2, revision: 4, questionCount: 2,
        entryCount: 12, createdAt: .distantPast, updatedAt: .distantPast, questions: questions)
    static let okReport = CompatibilityReport(
        ok: true, nextVersion: 3, issues: [], changes: [.init(kind: .added, questionKey: "energy", details: [])])

    let writer = FakeVersionWriter(server: topic, report: okReport)
    let toasts = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let published = Log()
    let model: EditQuestionsModel

    @MainActor final class Log {
        var topics: [Topic] = []
    }

    init() {
        let published = published
        model = EditQuestionsModel(
            topic: Self.topic, timer: nil, writer: writer, toasts: toasts,
            onPublished: { published.topics.append($0) })
    }

    var titles: [String] { toasts.items.map(\.toast.title) }

    /// Adds a whole-number "Energy" question.
    func addEnergy() {
        model.addQuestion(.int)
        let id = model.draft.questions.last!.id
        model.draft.setLabel(id, "Energy")
    }

    static let conflict = Problem(
        code: .conflict, detail: "topic is at version 3, but this edit was based on version 2")

    // MARK: Start

    @Test func startsFromTheCurrentVersionAllPublishedAndClosed() {
        #expect(model.draft.questions.map(\.key) == ["mood", "where"])
        #expect(model.draft.questions.allSatisfy { $0.locked })
        #expect(model.draft.questions.allSatisfy { !model.isOpen($0.id) }, "editing starts collapsed")
        #expect(model.nextVersion == 3)
        #expect(!model.hasUnsavedChanges)
    }

    @Test func anAddedQuestionOpensAndMakesItDirty() {
        addEnergy()
        let added = model.draft.questions.last!
        #expect(added.key == "energy" && !added.locked)
        #expect(model.isOpen(added.id))
        #expect(model.hasUnsavedChanges)
    }

    // MARK: Review

    @Test func reviewChecksAgainstTheBaseAndShowsTheReport() async {
        addEnergy()
        await model.reviewChanges()
        #expect(writer.calls == [.check(keys: ["mood", "where", "energy"], base: 2)])
        #expect(model.review?.report == Self.okReport)
        #expect(model.review?.version.questions.map(\.key) == ["mood", "where", "energy"])
        #expect(model.visibleBanner == nil)
    }

    @Test func anInvalidDraftIsNotSentAndOpensTheCard() async {
        model.addQuestion(.int)
        let id = model.draft.questions.last!.id
        await model.reviewChanges()
        #expect(writer.calls.isEmpty)
        #expect(model.visibleBanner == EditQuestionsModel.clientInvalid)
        #expect(model.draftErrors[.question(2, .label)] == BuilderMessage.required)
        #expect(model.isOpen(id), "a card with an error is open")
        // Fixing it clears the banner (validation follows edits after the first review).
        model.draft.setLabel(id, "Energy")
        #expect(model.draftErrors.isEmpty)
        #expect(model.visibleBanner == nil)
    }

    @Test func blockingIssuesLightUpTheirQuestion() async {
        writer.report = CompatibilityReport(
            ok: false, nextVersion: 3,
            issues: [
                .init(level: .info, questionKey: nil, message: "note"),
                .init(level: .error, questionKey: "where", message: "option 'home' cannot be removed"),
            ], changes: [])
        model.draft.questions[1].options.removeFirst()
        await model.reviewChanges()
        #expect(model.review?.report.ok == false)
        #expect(model.draftErrors[.question(1, .key)] == "option 'home' cannot be removed")
        #expect(model.isOpen(model.draft.questions[1].id))
        await model.publish()
        #expect(writer.calls.count == 1, "a report that blocks never publishes")
    }

    @Test func aRejectedCheckLandsOnTheFieldsAndTheBanner() async {
        writer.checkResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "bad",
                errors: [
                    FieldIssue(
                        location: [.key("body"), .key("questions"), .index(0), .key("label")], message: "too long"),
                    FieldIssue(location: [.key("body"), .key("base_version")], message: "odd"),
                ]))
        await model.reviewChanges()
        #expect(model.review == nil)
        #expect(model.draftErrors[.question(0, .label)] == "Too long")
        #expect(model.bannerDetails == ["Odd"])
        #expect(model.visibleBanner != nil)
    }

    @Test func offlineSaysSoInTheBanner() async {
        writer.checkResult = .offline
        await model.reviewChanges()
        #expect(model.visibleBanner == TopicWriteMessage.offline)
        #expect(model.review == nil)
    }

    // MARK: Publish

    @Test func publishSendsTheReviewedQuestionsAndTheNote() async {
        addEnergy()
        await model.reviewChanges()
        model.draft.changeNote = "  track energy too \n"
        await model.publish()
        #expect(writer.calls.last == .publish(keys: ["mood", "where", "energy"], base: 2, note: "track energy too"))
        #expect(model.review == nil)
        #expect(titles == ["Published v3"])
        #expect(published.topics.map(\.currentVersion) == [3])
        #expect(!model.hasUnsavedChanges, "leaving after publishing doesn't ask")
    }

    @Test func publishSendsWhatWasReviewedAndKeepsLaterEdits() async {
        addEnergy()
        await model.reviewChanges()
        // A valid edit after the review: not what was reviewed.
        model.addQuestion(.str)
        model.draft.setLabel(model.draft.questions.last!.id, "Notes")
        await model.publish()
        #expect(writer.calls.last == .publish(keys: ["mood", "where", "energy"], base: 2, note: ""))
        #expect(published.topics.isEmpty, "it stays: the later edit isn't published")
        #expect(model.draft.questions.map(\.key) == ["mood", "where", "energy", "notes"])
        #expect(model.hasUnsavedChanges)
        #expect(model.visibleBanner == EditQuestionsModel.changedWhilePublishing)
    }

    // MARK: Answers arriving late (Codex r1)

    @Test func aCheckAnsweredAfterAnEditDoesntOpenTheReview() async {
        addEnergy()
        let gate = Gate()
        writer.checkGate = gate
        let checking = Task { await model.reviewChanges() }
        await eventually("the check is out") { writer.calls.count == 1 }
        #expect(model.isBusy)
        model.draft.setLabel(model.draft.questions[2].id, "Energy level")
        gate.open()
        await checking.value
        #expect(model.review == nil, "the report is for the questions before the edit")
        #expect(model.visibleBanner == EditQuestionsModel.changedWhileChecking)
        #expect(model.draft.questions[2].label == "Energy level", "the edit is kept")
        #expect(!model.isBusy)
        // Reviewing again checks the questions as they are now.
        writer.checkGate = nil
        await model.reviewChanges()
        #expect(model.review?.checked.questions == model.draft.questions)
        #expect(model.visibleBanner == nil)
    }

    @Test func keepEditingWaitsForAPublish() async {
        addEnergy()
        await model.reviewChanges()
        let gate = Gate()
        writer.publishGate = gate
        let publishing = Task { await model.publish() }
        await eventually("the publish is out") { writer.calls.count == 2 }
        model.closeReview()
        #expect(model.review != nil, "the review stays open while publishing")
        gate.open()
        await publishing.value
        #expect(model.review == nil)
        #expect(published.topics.map(\.currentVersion) == [3])
    }

    @Test func aPublishAnsweredAfterAnEditKeepsTheEditAndStays() async {
        addEnergy()
        await model.reviewChanges()
        let gate = Gate()
        writer.publishGate = gate
        let publishing = Task { await model.publish() }
        await eventually("the publish is out") { writer.calls.count == 2 }
        model.draft.setLabel(model.draft.questions[0].id, "Feeling")
        gate.open()
        await publishing.value
        #expect(published.topics.isEmpty)
        #expect(model.hasUnsavedChanges)
        #expect(model.draft.questions[0].label == "Feeling")
        #expect(titles == ["Published v3"], "it did publish what was reviewed")
        #expect(model.visibleBanner == EditQuestionsModel.changedWhilePublishing)
    }

    @Test func keepMyDraftDropsAReloadInFlight() async {
        addEnergy()
        writer.checkResult = .rejected(Self.conflict)
        await model.reviewChanges()
        var newer = Self.topic
        newer.currentVersion = 3
        writer.server = newer
        let gate = Gate()
        writer.latestGate = gate
        let reloading = Task { await model.reloadLatest() }
        await eventually("the reload is out") { writer.calls.last == .latest }
        #expect(model.isReloading)
        model.keepDraft()
        #expect(!model.showsConflict && !model.isReloading)
        gate.open()
        await reloading.value
        #expect(model.base.currentVersion == 2, "the late answer doesn't rebase")
        #expect(model.draft.questions.map(\.key) == ["mood", "where", "energy"])
        #expect(model.hasUnsavedChanges)
        #expect(titles.isEmpty)
    }

    // MARK: Option text (Codex r1 minor)

    @Test func typedOptionTextIsAnUnsavedChangeUntilAdded() {
        let whereId = model.draft.questions[1].id
        model.newOptionLabels[whereId] = "   "
        #expect(!model.hasUnsavedChanges, "blank text isn't a change")
        model.newOptionLabels[whereId] = " Gym "
        #expect(model.hasUnsavedChanges)
        model.addPendingOption(to: whereId)
        #expect(model.draft.questions[1].options.map(\.label) == ["Home", "Work", "Gym"])
        #expect(model.newOptionLabels[whereId] == nil)
    }

    @Test func aTooLongNoteIsCaughtBeforeSending() async {
        addEnergy()
        await model.reviewChanges()
        model.draft.changeNote = String(repeating: "é", count: model.limits.maxChangeNoteLength + 1)
        await model.publish()
        #expect(writer.calls.count == 1)
        #expect(model.noteError == "At most \(model.limits.maxChangeNoteLength) characters")
        #expect(model.review != nil, "the review stays open to fix it")
    }

    @Test func anIncompatiblePublishClosesTheReviewWithTheServersMessage() async {
        addEnergy()
        await model.reviewChanges()
        let problem = Problem(code: .incompatibleVersion, detail: "mood: type cannot change (int -> double)")
        writer.publishResult = .rejected(problem)
        await model.publish()
        #expect(model.review == nil)
        #expect(model.visibleBanner == ProblemMapping.banner(for: problem))
        #expect(published.topics.isEmpty)
    }

    // MARK: Conflict

    @Test func aStaleCheckOpensTheConflictSheet() async {
        addEnergy()
        writer.checkResult = .rejected(Self.conflict)
        await model.reviewChanges()
        #expect(model.showsConflict)
        #expect(model.review == nil)
        #expect(model.visibleBanner == nil)
    }

    @Test func aStalePublishOpensTheConflictSheetAndKeepsTheDraft() async {
        addEnergy()
        await model.reviewChanges()
        writer.publishResult = .rejected(Self.conflict)
        await model.publish()
        #expect(model.showsConflict)
        #expect(model.review == nil)
        model.keepDraft()
        #expect(!model.showsConflict)
        #expect(model.draft.questions.map(\.key) == ["mood", "where", "energy"], "the draft is kept to copy from")
        #expect(model.hasUnsavedChanges)
    }

    @Test func loadingTheLatestStartsOverFromIt() async {
        addEnergy()
        writer.checkResult = .rejected(Self.conflict)
        await model.reviewChanges()
        var newer = Self.topic
        newer.currentVersion = 3
        newer.questions = Self.questions + [Question(key: "sleep", label: "Sleep", kind: .double(.init()))]
        writer.server = newer
        model.preview.set(.text("3"), for: BuilderPreview.questions(model.draft)[0])
        await model.reloadLatest()
        #expect(!model.showsConflict)
        #expect(model.base.currentVersion == 3 && model.nextVersion == 4)
        #expect(model.draft.questions.map(\.key) == ["mood", "where", "sleep"])
        #expect(model.draft.questions.allSatisfy { $0.locked })
        #expect(!model.hasUnsavedChanges)
        #expect(model.draftErrors.isEmpty && model.visibleBanner == nil)
        #expect(model.preview.inputs.isEmpty)
        #expect(titles == ["Loaded v3"])
        // The next review is based on the new version.
        await model.reviewChanges()
        #expect(writer.calls.last == .check(keys: ["mood", "where", "sleep"], base: 3))
    }

    @Test func aFailedReloadKeepsEverything() async {
        addEnergy()
        writer.checkResult = .rejected(Self.conflict)
        await model.reviewChanges()
        writer.latestResult = .offline
        await model.reloadLatest()
        #expect(model.showsConflict, "the sheet stays to try again")
        #expect(model.base.currentVersion == 2)
        #expect(model.draft.questions.map(\.key) == ["mood", "where", "energy"])
        #expect(titles == ["Could not reload"])
        #expect(toasts.items.last?.toast.message == TopicWriteMessage.offline)
    }

    // MARK: Labels

    @Test func reportLabelsComeFromTheDraftThenTheBase() {
        addEnergy()
        model.draft.questions[0].label = ""
        #expect(model.label(forKey: "energy") == "Energy")
        #expect(model.label(forKey: "mood") == "Mood", "a blanked label falls back to the published one")
        #expect(model.label(forKey: "gone") == "gone")
    }
}

/// The Timed switch and the steps editor in the question editor (timers.md §2.1, §11.2).
@MainActor @Suite struct EditQuestionsTimerTests {
    static let timer = TopicTimer(steps: [.init(key: "shower", label: "Shower"), .init(key: "dress", label: "Dress")])
    static let history = [
        HistoricStep(key: "prep", label: "Old prep"), HistoricStep(key: "shower", label: "Shower"),
        HistoricStep(key: "dress", label: "Dress"),
    ]
    static let noQuestionChanges = CompatibilityReport(ok: true, nextVersion: 3, issues: [], changes: [])

    let writer = FakeVersionWriter(server: EditQuestionsModelTests.topic, report: noQuestionChanges)
    let toasts = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let model: EditQuestionsModel

    init() {
        model = EditQuestionsModel(
            topic: EditQuestionsModelTests.topic, timer: Self.timer, stepHistory: Self.history, writer: writer,
            toasts: toasts)
    }

    @Test func opensWithThePublishedStepsLocked() {
        #expect(model.draft.timed)
        let keys = model.draft.steps.map(\.key)
        #expect(keys == ["shower", "dress"])
        let locked = model.draft.steps.allSatisfy { $0.locked }
        #expect(locked)
        #expect(!model.hasUnsavedChanges)
    }

    @Test func aRenameKeepsThePublishedKeyAndIsSent() async {
        model.setStepLabel(model.draft.steps[0].id, "Bath")
        let key = model.draft.steps[0].key
        #expect(key == "shower")
        await model.reviewChanges()
        let sent: TopicTimer? = writer.versions.last?.timer
        #expect(sent == TopicTimer(steps: [.init(key: "shower", label: "Bath"), .init(key: "dress", label: "Dress")]))
    }

    @Test func aNewStepNamedLikeARetiredOneTakesItsKeyBack() {
        let id = model.addStep()!
        model.setStepLabel(id, "old prep")
        let key: String? = model.draft.steps.last?.key
        #expect(key == "prep")
        model.setStepLabel(id, "Prep")
        let other: String? = model.draft.steps.last?.key
        #expect(other == "prep_2", "a key no version has used")
    }

    @Test func aTimerOnlyChangeIsReviewedAndPublished() async {
        model.draft.moveStep(model.draft.steps[1].id, to: 0)
        await model.reviewChanges()
        let timerChanges: [String]? = model.review?.timerChanges
        let emptyText: String? = model.review?.emptyChangesText
        #expect(timerChanges == ["Steps reordered"])
        #expect(emptyText == "No question changes.")
        let checked: [String]? = writer.versions.first?.timer?.steps.map { $0.key }
        #expect(checked == ["dress", "shower"], "the check sends the timer")
        await model.publish()
        let published: [String]? = writer.versions.last?.timer?.steps.map { $0.key }
        #expect(published == ["dress", "shower"])
    }

    @Test func timedOffSendsNullAndOnRestoresTheSteps() async {
        model.draft.timed = false
        await model.reviewChanges()
        let off: TopicDraft.Version? = writer.versions.last
        #expect(off != nil)
        let offTimer: TopicTimer? = off?.timer
        #expect(offTimer == nil)
        let changes: [String]? = model.review?.timerChanges
        #expect(changes == ["No longer timed"])
        model.closeReview()
        model.draft.timed = true
        let keys = model.draft.steps.map(\.key)
        #expect(keys == ["shower", "dress"])
        #expect(!model.hasUnsavedChanges)
    }

    @Test func aBlankStepBlocksTheReview() async {
        model.addStep()
        await model.reviewChanges()
        #expect(model.review == nil)
        #expect(writer.calls.isEmpty)
        let error = model.draftErrors[.step(2, .label)]
        #expect(error == "Required")
    }

    @Test func aStepEditedWhileCheckingDropsTheReport() async {
        model.setStepLabel(model.draft.steps[0].id, "Bath")
        let gate = Gate()
        writer.checkGate = gate
        let checking = Task { await model.reviewChanges() }
        await eventually("the check is out") { writer.calls.count == 1 }
        model.setStepLabel(model.draft.steps[0].id, "Bath time")
        gate.open()
        await checking.value
        #expect(model.review == nil)
        #expect(model.visibleBanner == EditQuestionsModel.changedWhileChecking)
    }

    /// "Load latest version" reads every version's steps: a key retired in a version published
    /// meanwhile is still taken back by its label, never reused for another step.
    @Test func loadingTheLatestVersionExtendsTheHistoryFromEveryVersion() async {
        writer.checkResult = .rejected(EditQuestionsModelTests.conflict)
        await model.reviewChanges()
        var latest = EditQuestionsModelTests.topic
        latest.currentVersion = 4
        latest.timer = TopicTimer(steps: [.init(key: "shower", label: "Shower")])
        writer.latestResult = .done(latest)
        let v3 = TopicVersion(
            version: 3, questions: [], timer: TopicTimer(steps: [.init(key: "wash", label: "Rinse")]),
            createdAt: .distantPast)
        let v4 = TopicVersion(version: 4, questions: [], timer: latest.timer, createdAt: .distantPast)
        writer.versionsResult = .done([v4, v3])
        await model.reloadLatest()
        let base: Int = model.base.currentVersion
        #expect(base == 4)
        let id = model.addStep()!
        model.setStepLabel(id, "rinse")
        let retired: String? = model.draft.steps.last?.key
        #expect(retired == "wash", "v3's retired step, taken back")
        model.setStepLabel(id, "Old prep")
        let older: String? = model.draft.steps.last?.key
        #expect(older == "prep", "the history from before the reload is kept")
        model.setStepLabel(id, "Dress")
        let dress: String? = model.draft.steps.last?.key
        #expect(dress == "dress", "dress is retired (not in v4) and free: taken back")
    }

    @Test func aServerStepErrorLandsOnTheStep() async {
        writer.checkResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "invalid",
                errors: [
                    .init(
                        location: [.key("body"), .key("timer"), .key("steps"), .index(1), .key("key")],
                        message: "duplicate key")
                ]))
        await model.reviewChanges()
        let error = model.draftErrors[.step(1, .key)]
        #expect(error == "Duplicate key")
    }
}

@Suite struct CompatReportTextTests {
    @Test func headlineAndOrder() {
        let report = CompatibilityReport(
            ok: false, nextVersion: 4,
            issues: [
                .init(level: .info, questionKey: nil, message: "i1"),
                .init(level: .warning, questionKey: "a", message: "w1"),
                .init(level: .error, questionKey: "b", message: "e1"),
                .init(level: .info, questionKey: nil, message: "i2"),
                .init(level: .error, questionKey: "c", message: "e2"),
            ], changes: [])
        #expect(CompatReportText.headline(report) == "Can’t publish yet — fix the errors below")
        #expect(CompatReportText.sortedIssues(report).map(\.message) == ["e1", "e2", "w1", "i1", "i2"])
        var ok = report
        ok.ok = true
        #expect(CompatReportText.headline(ok) == "Ready to publish as v4")
    }

    @Test func changeSubjects() {
        let order = CompatibilityReport.Change(kind: .reordered, questionKey: "*", details: [])
        let added = CompatibilityReport.Change(kind: .added, questionKey: "x", details: [])
        #expect(CompatReportText.subject(order) { $0.uppercased() } == "Question order")
        #expect(CompatReportText.subject(added) { $0.uppercased() } == "X")
        #expect(
            CompatibilityReport.ChangeKind.allCases.map(CompatReportText.kindLabel) == [
                "added", "removed", "changed", "restored", "reordered",
            ])
    }
}
