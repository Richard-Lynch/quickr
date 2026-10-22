import Foundation
import QuickrCore
import QuickrUI
import Testing

@MainActor @Suite struct NewTopicModelTests {
    static let created = Topic(
        id: UUID(), slug: "water", name: "Water", description: "", currentVersion: 1, revision: 1, questionCount: 1,
        createdAt: .distantPast, updatedAt: .distantPast,
        questions: [Question(key: "glasses", label: "Glasses", kind: .int(.init()))])

    let writer = FakeTopicWriter(server: Self.created)
    let toasts = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let opened = Opened()
    let model: NewTopicModel

    @MainActor final class Opened {
        var topics: [Topic] = []
    }

    init() {
        let opened = opened
        model = NewTopicModel(
            writer: writer, toasts: toasts, deviceTimeZone: "Europe/London", onCreated: { opened.topics.append($0) })
    }

    /// A valid draft: a name and one labelled whole-number question.
    func fill() {
        model.draft.setName("Water")
        model.addQuestion(.int)
        let id = model.draft.questions[0].id
        model.draft.setLabel(id, "Glasses")
    }

    @Test func aFreshFormHasNothingToLose() {
        #expect(!model.hasUnsavedChanges)
        model.draft.setName("W")
        #expect(model.hasUnsavedChanges)
    }

    @Test func createSendsTheDraftAndOpensTheTopic() async {
        fill()
        #expect(model.draft.slug == "water", "the slug follows the name")
        await model.create()
        #expect(writer.calls == [.create(name: "Water", schedule: nil)])
        #expect(toasts.items.map(\.toast.title) == ["Topic created"])
        #expect(toasts.items.first?.toast.message == "Log your first entry.")
        #expect(opened.topics == [Self.created])
    }

    /// SINGLE: a new topic starts with no questions, and creates as is (logged in one tap).
    @Test func aTopicWithNoQuestionsCreates() async {
        #expect(model.draft.questions.isEmpty)
        model.draft.setName("Water")
        await model.create()
        #expect(writer.calls == [.create(name: "Water", schedule: nil)])
        #expect(model.draftErrors.isEmpty)
    }

    @Test func createSendsTheSchedule() async {
        fill()
        model.schedule.kind = .interval
        model.schedule.every = "3"
        model.schedule.unit = .hours
        await model.create()
        #expect(
            writer.calls == [
                .create(name: "Water", schedule: .interval(.init(everyMinutes: 180, timezone: "Europe/London")))
            ])
    }

    /// TP6: the banner's VoiceOver focus re-fires per attempt (`qrAnnouncesError`'s trigger), so an
    /// identical error on a second try is read again.
    @Test func eachCreateIsANewAttemptEvenWithTheSameError() async {
        #expect(model.attempts == 0)
        await model.create()
        let first = model.visibleBanner
        #expect(first == NewTopicModel.clientInvalid && model.attempts == 1)
        await model.create()
        #expect(model.visibleBanner == first, "the same message")
        #expect(model.attempts == 2, "but a new trigger")
        #expect(QuickrErrorFocusRule.shouldFocus(from: (first, 1), to: (model.visibleBanner, model.attempts)))
    }

    @Test func anInvalidFormIsNotSentAndRevalidatesAsItIsFixed() async {
        model.schedule.kind = .daily
        model.schedule.days = []
        await model.create()
        #expect(writer.calls.isEmpty)
        #expect(model.visibleBanner == NewTopicModel.clientInvalid)
        #expect(model.draftErrors[.name] == BuilderMessage.topicName)
        #expect(model.scheduleErrors[.days] == ScheduleMessage.pickDay)

        fill()
        model.schedule.days = [1]
        #expect(model.draftErrors.isEmpty && model.scheduleErrors.isEmpty)
        #expect(model.visibleBanner == nil, "no field shows an error any more")
    }

    @Test func serverErrorsLandOnTheirFieldsAndTheRestUnderTheBanner() async {
        fill()
        model.schedule.kind = .daily
        writer.topicResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "Request validation failed",
                errors: [
                    FieldIssue(
                        location: [.key("body"), .key("questions"), .index(0), .key("max")], message: "too big"),
                    FieldIssue(location: [.key("body"), .key("schedule"), .key("times"), .index(4)], message: "bad"),
                    FieldIssue(location: [.key("body"), .key("schedule"), .key("timezone")], message: "unknown zone"),
                    FieldIssue(location: [.key("body"), .key("colour")], message: "extra field"),
                ]))
        await model.create()
        #expect(model.draftErrors[.question(0, .max)] == "Too big")
        #expect(model.scheduleErrors[.times] == "Bad", "a time the draft doesn't have lights up the list")
        #expect(model.scheduleErrors[.timezone] == "Unknown zone")
        #expect(model.visibleBanner == "Some fields need attention")
        #expect(model.bannerDetails == ["Extra field"])
        #expect(opened.topics.isEmpty)
    }

    @Test func aTakenSlugIsABanner() async {
        fill()
        writer.topicResult = .rejected(Problem(code: .conflict, detail: "slug 'water' is already taken"))
        await model.create()
        #expect(model.visibleBanner == "Slug 'water' is already taken")
    }

    @Test func offlineSaysNeedsAConnectionAndKeepsTheForm() async {
        fill()
        writer.topicResult = .offline
        await model.create()
        #expect(model.visibleBanner == TopicWriteMessage.offline)
        #expect(model.draft.name == "Water")
        #expect(opened.topics.isEmpty)
    }

    @Test func typeLabelsAreThePWAs() {
        #expect(QuestionType.allCases.map(\.builderLabel) == ["Whole number", "Decimal number", "Text", "Choice"])
    }
}
