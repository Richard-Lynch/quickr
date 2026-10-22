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
        await checkGate?.wait()
        return checkResult ?? .done(report)
    }

    func publishVersion(_ version: TopicDraft.Version, baseVersion: Int, changeNote: String, topicId: UUID) async
        -> TopicWriteOutcome<Topic>
    {
        calls.append(.publish(keys: version.questions.map(\.key), base: baseVersion, note: changeNote))
        await publishGate?.wait()
        if let publishResult { return publishResult }
        server.currentVersion += 1
        server.questions = version.questions
        return .done(server)
    }

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
            topic: Self.topic, writer: writer, toasts: toasts, onPublished: { published.topics.append($0) })
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
        #expect(model.review?.questions == model.draft.questions)
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
