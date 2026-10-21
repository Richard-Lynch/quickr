import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// `LogTopicIntent`'s question loop and confirmation snippet, without Siri (spike S4: the prompts
/// can't be driven from AppIntentsTesting), and the Foundation Model path's mapping.
@Suite(.timeLimit(.minutes(5))) struct IntentDraftTests {
    static let hours = Question(
        key: "hours", label: "Hours slept", kind: .double(.init(min: 0, max: 24, decimals: 1, unit: "h")))
    static let quality = Question(
        key: "quality", label: "Quality",
        kind: .choice(
            .init(options: [
                .init(value: "good", label: "Good"), .init(value: "ok", label: "OK"),
                .init(value: "gone", label: "Gone", archived: true),
            ])))
    static let woke = Question(key: "woke", label: "Woke up", kind: .int(.init(min: 0, max: 10)))
    static let factors = Question(
        key: "factors", label: "Factors", required: false,
        kind: .choice(
            .init(
                options: [.init(value: "coffee", label: "Coffee"), .init(value: "screens", label: "Screens")],
                multiple: true)))
    static let note = Question(key: "note", label: "Note", required: false, kind: .string(.init()))

    static let sleep: Topic = {
        var topic = Make.topic(name: "Sleep")
        topic.questions = [hours, quality, woke, factors, note]
        return topic
    }()

    // MARK: - The loop

    /// Required questions in order; optional ones are left to the snippet.
    @Test func theLoopAsksTheRequiredQuestionsInOrder() throws {
        var draft = IntentDraft(topic: Self.sleep)
        #expect(draft.next == .number(Self.hours))
        #expect(draft.answer("hours", .double(7.5)) == nil)
        #expect(
            draft.next == .option(Self.quality, [.init(value: "good", label: "Good"), .init(value: "ok", label: "OK")]))
        draft.answer("quality", .string("good"))
        #expect(draft.next == .number(Self.woke))
        draft.answer("woke", .int(2))
        #expect(draft.next == nil)
        #expect(try draft.validated.get() == ["hours": .double(7.5), "quality": .string("good"), "woke": .int(2)])
    }

    /// An invalid answer is refused with its message and asked again.
    @Test func anInvalidAnswerIsAskedAgain() {
        var draft = IntentDraft(topic: Self.sleep)
        #expect(draft.answer("hours", .double(30)) != nil)
        #expect(draft.next == .number(Self.hours) && draft.answers.isEmpty)
        #expect(draft.answer("woke", .double(1.5)) != nil, "an int question")
        #expect(draft.answer("quality", .string("gone")) != nil, "an archived option")
        #expect(draft.answer("nope", .int(1)) != nil)
    }

    /// Prefilled answers (the FM path) count only when they validate; the rest is asked.
    @Test func prefilledAnswersOnlyCountWhenValid() {
        let draft = IntentDraft(topic: Self.sleep, answers: ["hours": .double(7), "quality": .string("bogus")])
        #expect(draft.answers == ["hours": .double(7)])
        #expect(draft.next?.question == Self.quality)
    }

    // MARK: - The snippet

    @Test func theSnippetEditsTheDraft() {
        var draft = IntentDraft(topic: Self.sleep)
        draft.step("hours", by: 1)
        #expect(draft.answers["hours"] == .double(0.1), "from the minimum, by one decimal")
        draft.answer("hours", .double(23.95))
        draft.step("hours", by: 1)
        #expect(draft.answers["hours"] == .double(24), "rounded to a step, capped at the max")
        draft.step("woke", by: -1)
        #expect(draft.answers["woke"] == .int(0), "never below the minimum")
        draft.set("quality", option: "ok")
        #expect(draft.answers["quality"] == .string("ok"))
        draft.toggle("factors", option: "screens")
        draft.toggle("factors", option: "coffee")
        #expect(draft.answers["factors"] == .strings(["coffee", "screens"]), "in option order")
        draft.toggle("factors", option: "coffee")
        draft.toggle("factors", option: "screens")
        #expect(draft.answers["factors"] == nil)
        draft.toggle("quality", option: "good")
        #expect(draft.answers["quality"] == .string("ok"), "toggle is for multi-selects only")
    }

    /// A multi-select's in-between states are kept and reported; removing the last option of a
    /// required one doesn't get past validation.
    @Test func multiSelectEditsKeepInBetweenStatesAndReportThem() {
        let options = Question.ChoiceRules(
            options: [.init(value: "a", label: "A"), .init(value: "b", label: "B"), .init(value: "c", label: "C")],
            multiple: true, minSelected: 2)
        let optional = Question(key: "pairs", label: "Pairs", required: false, kind: .choice(options))
        let required = Question(
            key: "tags", label: "Tags", kind: .choice(.init(options: options.options, multiple: true)))
        var topic = Make.topic(name: "Pick")
        topic.questions = [optional, required]
        var draft = IntentDraft(topic: topic, answers: ["tags": .strings(["a"])])

        draft.toggle("pairs", option: "b")
        #expect(draft.answers["pairs"] == .strings(["b"]), "one of two: kept")
        #expect(draft.problem(for: optional) != nil)
        if case .success = draft.validated { Issue.record("not valid yet") }
        draft.toggle("pairs", option: "a")
        #expect(draft.problem(for: optional) == nil && draft.answers["pairs"] == .strings(["a", "b"]))
        #expect((try? draft.validated.get()) == ["pairs": .strings(["a", "b"]), "tags": .strings(["a"])])

        draft.toggle("tags", option: "a")
        #expect(draft.answers["tags"] == nil && draft.problem(for: required) == "Tags is required.")
        if case .success = draft.validated { Issue.record("a required multi-select emptied") }
        #expect(draft.firstProblem == "Tags is required.")
    }

    @Test func draftsAreHeldByIdAndBounded() {
        let draft = IntentDraft(topic: Self.sleep)
        IntentDrafts.put(draft)
        #expect(IntentDrafts.update(draft.id) { $0.answer("woke", .int(3)) }?.answers["woke"] == .int(3))
        #expect(IntentDrafts.get(draft.id)?.answers["woke"] == .int(3))
        IntentDrafts.remove(draft.id)
        #expect(IntentDrafts.get(draft.id) == nil && IntentDrafts.update(draft.id) { _ in } == nil)
        let many = (0...IntentDrafts.limit).map { _ in IntentDraft(topic: Self.sleep) }
        for draft in many { IntentDrafts.put(draft) }
        #expect(IntentDrafts.get(many[0].id) == nil, "the oldest went")
        #expect(IntentDrafts.get(many.last!.id) != nil)
        for draft in many { IntentDrafts.remove(draft.id) }
    }

    // MARK: - The Foundation Model path

    @Test func theModelSeesEachQuestionWithItsUnitAndOptionLabels() {
        let fields = AnswerExtraction.fields(for: Self.sleep.questions)
        #expect(fields.map(\.key) == ["hours", "quality", "woke", "factors", "note"])
        #expect(fields[0].field == .number(description: "Hours slept (h)"))
        #expect(fields[1].field == .choice(description: "Quality", labels: ["Good", "OK"]))
        #expect(fields[3].field == .choices(description: "Factors", labels: ["Coffee", "Screens"]))
        #expect(fields[4].field == .text(description: "Note"))
    }

    /// Labels back to values, numbers typed by their question, junk dropped.
    @Test func whatTheModelSaidBecomesAnswers() {
        let json = """
            {"hours": 7.5, "quality": "good", "woke": 2.0, "factors": ["Screens", "coffee", "nope"],
             "note": "  ", "extra": 1}
            """
        #expect(
            AnswerExtraction.answers(fromJSON: json, questions: Self.sleep.questions)
                == [
                    "hours": .double(7.5), "quality": .string("good"), "woke": .int(2),
                    "factors": .strings(["coffee", "screens"]),
                ])
        #expect(AnswerExtraction.answers(fromJSON: #"{"quality": "Great"}"#, questions: Self.sleep.questions).isEmpty)
        #expect(AnswerExtraction.answers(fromJSON: "not json", questions: Self.sleep.questions).isEmpty)
        #expect(
            AnswerExtraction.answers(fromJSON: #"{"hours": true, "woke": false}"#, questions: Self.sleep.questions)
                .isEmpty,
            "a boolean isn't a number")
    }

    // MARK: - The model's deadline

    @Test func aFastAnswerComesBackAndAFailureIsNoAnswer() async throws {
        #expect(try await AnswerExtraction.withDeadline(.seconds(5)) { 42 } == 42)
        struct Boom: Error {}
        #expect(try await AnswerExtraction.withDeadline(.seconds(5)) { () async throws -> Int in throw Boom() } == nil)
    }

    /// A model call that ignores cancellation is abandoned at the deadline, not waited for.
    @Test func aStuckModelIsAbandonedAtTheDeadline() async throws {
        let (stream, release) = AsyncStream.makeStream(of: Void.self)
        let started = ContinuousClock.now
        let value = try await AnswerExtraction.withDeadline(.milliseconds(100)) { () async -> Int in
            for await _ in stream {}  // ignores cancellation until released
            return 1
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - started < .seconds(20))
        release.finish()
    }

    /// The intent's own cancellation (the system's 30 s) propagates instead of reading as no answers.
    @Test func theCallersCancellationIsThrown() async {
        let task = Task {
            try await AnswerExtraction.withDeadline(.seconds(60)) { () async throws -> Int in
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    #if canImport(FoundationModels)
    @Test func theSchemaBuilds() throws {
        _ = try OnDeviceAnswerExtractor.schema(for: Self.sleep)
    }
    #endif
}
