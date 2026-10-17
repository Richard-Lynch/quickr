import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// TS/Python/Swift parity for quick-log: every case in shared/fixtures/quicklog-vectors.json
/// (generated from backend/app/services/quicklog.py; the PWA asserts the same cases).
@Suite struct QuickLogVectorTests {
    @Test func hasCases() {
        #expect(QuickLogVectors.shared.eligibility.count == 23)
        #expect(QuickLogVectors.shared.initial.count == 357)
        #expect(QuickLogVectors.shared.chipLimit == QuickLog.chipLimit)
    }

    @Test(arguments: QuickLogVectors.shared.eligibility)
    func eligibility(_ vector: QuickLogVectors.Eligibility) {
        #expect(QuickLogVectors.Descriptor(QuickLog(questions: vector.questions)) == vector.expected)
    }

    @Test(arguments: QuickLogVectors.shared.initial)
    func initialValue(_ vector: QuickLogVectors.Initial) {
        #expect(QuickLog.initialText(for: vector.question, last: vector.last) == vector.expected)
    }
}

/// The vectors file, decoded into QuickrCore types.
struct QuickLogVectors: Decodable {
    static let shared: QuickLogVectors = {
        do {
            return try JSONDecoder().decode(QuickLogVectors.self, from: Fixtures.quicklogVectors())
        } catch {
            fatalError("quicklog-vectors.json: \(error)")
        }
    }()

    var eligibility: [Eligibility]
    var initial: [Initial]
    var chipLimit: Int

    enum CodingKeys: String, CodingKey {
        case eligibility, initial, meta
    }

    enum MetaKeys: String, CodingKey {
        case quickChipLimit = "quick_chip_limit"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligibility = try container.decode([Eligibility].self, forKey: .eligibility)
        initial = try container.decode([Initial].self, forKey: .initial)
        chipLimit = try container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
            .decode(Int.self, forKey: .quickChipLimit)
    }

    struct Eligibility: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var questions: [Question]
        var expected: Descriptor?

        enum CodingKeys: String, CodingKey {
            case name, questions, expected
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            questions = try container.decode([VectorQuestion].self, forKey: .questions).map(\.question)
            expected = try container.decodeIfPresent(Descriptor.self, forKey: .expected)
        }

        var testDescription: String { name }
    }

    struct Initial: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var question: Question
        var last: AnswerValue?
        var expected: String

        enum CodingKeys: String, CodingKey {
            case name, question, last, expected
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            question = try container.decode(VectorQuestion.self, forKey: .question).question
            last = try container.decode(LastValue.self, forKey: .last).value
            expected = try container.decode(String.self, forKey: .expected)
        }

        var testDescription: String { name }
    }

    /// `{kind: "chips", key, options: [{value, label}]}` or `{kind: "number", key}`.
    struct Descriptor: Decodable, Hashable, Sendable {
        var kind: String
        var key: String
        var options: [Option]?

        struct Option: Decodable, Hashable, Sendable {
            var value: String
            var label: String
        }

        init?(_ quickLog: QuickLog?) {
            switch quickLog {
            case .chips(let question, let options):
                kind = "chips"
                key = question.key
                self.options = options.map { Option(value: $0.value, label: $0.label) }
            case .number(let question):
                kind = "number"
                key = question.key
                options = nil
            case nil:
                return nil
            }
        }
    }

    /// `last` is any JSON value. Numbers become answers; booleans, strings, lists and null are
    /// "no last number" as far as quick-log goes, so strings stay strings to prove that.
    struct LastValue: Decodable {
        var value: AnswerValue?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() || (try? container.decode(Bool.self)) != nil {
                value = nil
            } else if let n = try? container.decode(Int.self) {
                value = .int(n)
            } else if let x = try? container.decode(Double.self) {
                value = .double(x)
            } else if let s = try? container.decode(String.self) {
                value = .string(s)
            } else {
                _ = try container.decode([JSONValue].self)
                value = nil
            }
        }
    }
}

/// A question in the server's JSON shape (`QuestionOutput`).
struct VectorQuestion: Decodable {
    var question: Question

    enum CodingKeys: String, CodingKey {
        case key, label, type, required, unit, min, max, decimals, options, multiple
        case helpText = "help_text"
        case minLength = "min_length"
        case maxLength = "max_length"
        case multiline
        case minSelected = "min_selected"
        case maxSelected = "max_selected"
    }

    struct Option: Decodable {
        var value: String
        var label: String
        var archived: Bool
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind: Question.Kind
        switch try c.decode(String.self, forKey: .type) {
        case "int":
            kind = .int(
                .init(
                    min: try c.decodeIfPresent(Int.self, forKey: .min),
                    max: try c.decodeIfPresent(Int.self, forKey: .max),
                    unit: try c.decodeIfPresent(String.self, forKey: .unit)))
        case "double":
            kind = .double(
                .init(
                    min: try c.decodeIfPresent(Double.self, forKey: .min),
                    max: try c.decodeIfPresent(Double.self, forKey: .max),
                    decimals: try c.decodeIfPresent(Int.self, forKey: .decimals),
                    unit: try c.decodeIfPresent(String.self, forKey: .unit)))
        case "str":
            kind = .string(
                .init(
                    minLength: try c.decodeIfPresent(Int.self, forKey: .minLength) ?? 0,
                    maxLength: try c.decodeIfPresent(Int.self, forKey: .maxLength) ?? 500,
                    multiline: try c.decodeIfPresent(Bool.self, forKey: .multiline) ?? false))
        default:
            kind = .choice(
                .init(
                    options: try c.decode([Option].self, forKey: .options).map {
                        EnumOption(value: $0.value, label: $0.label, archived: $0.archived)
                    },
                    multiple: try c.decodeIfPresent(Bool.self, forKey: .multiple) ?? false,
                    minSelected: try c.decodeIfPresent(Int.self, forKey: .minSelected),
                    maxSelected: try c.decodeIfPresent(Int.self, forKey: .maxSelected)))
        }
        question = Question(
            key: try c.decode(String.self, forKey: .key), label: try c.decode(String.self, forKey: .label),
            helpText: try c.decodeIfPresent(String.self, forKey: .helpText),
            required: try c.decodeIfPresent(Bool.self, forKey: .required) ?? true, kind: kind)
    }
}
