import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/builder-ui-vectors.json`, from the PWA's own `builder.ts` and
/// `questionSummary.ts`: a new question's draft, the draft a published question opens as, the
/// live preview's question, and the versions list's constraint line (en-US).
@Suite struct BuilderUIVectorTests {
    @Test func hasCases() {
        #expect(BuilderUIVectors.shared.newQuestion.count == 4)
        #expect(BuilderUIVectors.shared.fromQuestion.count >= 20)
        #expect(BuilderUIVectors.shared.preview.count >= 25)
        #expect(BuilderUIVectors.shared.constraintText.count >= 10)
    }

    @Test(arguments: BuilderUIVectors.shared.newQuestion)
    func newQuestion(_ vector: BuilderUIVectors.NewQuestionCase) {
        #expect(PlainDraft(DraftQuestion(type: vector.type)) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.fromQuestion)
    func fromQuestion(_ vector: BuilderUIVectors.FromQuestionCase) {
        #expect(PlainDraft(DraftQuestion(question: vector.question.question, locked: vector.locked)) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.preview)
    func preview(_ vector: BuilderUIVectors.PreviewCase) {
        #expect(vector.draft.model.preview(index: vector.index) == vector.expected.question)
    }

    @Test(arguments: BuilderUIVectors.shared.constraintText)
    func constraintText(_ vector: BuilderUIVectors.ConstraintCase) {
        #expect(
            QuestionSummary.constraint(vector.question.question, locale: Locale(identifier: "en_US")) == vector.expected
        )
    }
}

struct BuilderUIVectors: Decodable {
    static let shared: BuilderUIVectors = {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(BuilderUIVectors.self, from: Fixtures.data("builder-ui-vectors.json"))
        } catch {
            fatalError("builder-ui-vectors.json: \(error)")
        }
    }()

    var newQuestion: [NewQuestionCase]
    var fromQuestion: [FromQuestionCase]
    var preview: [PreviewCase]
    var constraintText: [ConstraintCase]

    struct NewQuestionCase: Decodable, Sendable, CustomTestStringConvertible {
        var type: QuestionType
        var expected: PlainDraft
        var testDescription: String { type.rawValue }
    }

    struct FromQuestionCase: Decodable, Sendable, CustomTestStringConvertible {
        var question: QuestionJSON
        var locked: Bool
        var expected: PlainDraft
        var testDescription: String { "\(question.question.key) locked: \(locked)" }
    }

    struct PreviewCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var index: Int
        var draft: PlainDraft
        var expected: QuestionJSON
        var testDescription: String { name }
    }

    struct ConstraintCase: Decodable, Sendable, CustomTestStringConvertible {
        var question: QuestionJSON
        var expected: String
        var testDescription: String { "\(question.question.key): \(expected)" }
    }
}

/// A draft without its ids, in the vectors' spelling (the PWA's `DraftQuestion` fields).
struct PlainDraft: Decodable, Sendable, Equatable, CustomStringConvertible {
    var type: QuestionType
    var key, label, helpText: String
    var required, keyEdited, locked: Bool
    var min, max, unit, decimals, minLength, maxLength: String
    var multiline: Bool
    var options: [Option]
    var multiple: Bool
    var minSelected, maxSelected: String
    var publishedMultiple: Bool

    struct Option: Decodable, Sendable, Equatable {
        var value, label: String
        var archived, valueEdited, locked: Bool
    }

    init(_ d: DraftQuestion) {
        type = d.type
        key = d.key
        label = d.label
        helpText = d.helpText
        required = d.required
        keyEdited = d.keyEdited
        locked = d.locked
        min = d.min
        max = d.max
        unit = d.unit
        decimals = d.decimals
        minLength = d.minLength
        maxLength = d.maxLength
        multiline = d.multiline
        options = d.options.map {
            Option(
                value: $0.value, label: $0.label, archived: $0.archived, valueEdited: $0.valueEdited, locked: $0.locked)
        }
        multiple = d.multiple
        minSelected = d.minSelected
        maxSelected = d.maxSelected
        publishedMultiple = d.publishedMultiple
    }

    var model: DraftQuestion {
        var d = DraftQuestion(type: type)
        d.key = key
        d.label = label
        d.helpText = helpText
        d.required = required
        d.keyEdited = keyEdited
        d.locked = locked
        d.min = min
        d.max = max
        d.unit = unit
        d.decimals = decimals
        d.minLength = minLength
        d.maxLength = maxLength
        d.multiline = multiline
        d.options = options.map {
            DraftOption(
                value: $0.value, label: $0.label, archived: $0.archived, valueEdited: $0.valueEdited, locked: $0.locked)
        }
        d.multiple = multiple
        d.minSelected = minSelected
        d.maxSelected = maxSelected
        d.publishedMultiple = publishedMultiple
        return d
    }

    var description: String { "\(type.rawValue) \(key)" }
}
