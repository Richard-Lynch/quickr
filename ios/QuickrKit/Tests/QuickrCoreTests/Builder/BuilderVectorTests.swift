import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// shared/fixtures/builder-vectors.json, generated from the server
/// (backend/tests/test_builder_vectors.py): the builder accepts exactly the question lists the
/// server accepts and flags the field it names; the local compatibility check reports what
/// `check_compatibility` does; slugs match `slugify`.
@Suite struct BuilderVectorTests {
    /// Whole numbers past 2^53 - 1: the server takes them (up to int64); the PWA and iOS refuse
    /// them as "Number is too large", because a JS number (and the answer form) can't hold them.
    static let clientStricter: Set<String> = ["int/int64-max", "int/above-js-safe"]

    @Test func hasCases() {
        #expect(BuilderVectors.shared.questions.count > 100)
        #expect(BuilderVectors.shared.compat.count > 30)
        #expect(BuilderVectors.shared.slugs.count > 10)
    }

    @Test(arguments: BuilderVectors.shared.questions)
    func questions(_ vector: BuilderVectors.QuestionCase) {
        let topic = TopicDraft(questions: vector.drafts)
        let client = Set(paths(topic.validatedQuestions()).map { String($0.dropFirst("questions".count)) })
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        if Self.clientStricter.contains(vector.name) {
            #expect(vector.errors.isEmpty && !client.isEmpty, "\(vector.name): \(client)")
            return
        }
        #expect(client.isEmpty == vector.errors.isEmpty, "\(vector.name): client \(client), server \(vector.errors)")
        for loc in vector.errors {
            #expect(client.contains(loc), "\(vector.name): server rejects \(loc); client flags \(client)")
        }
    }

    @Test(arguments: BuilderVectors.shared.compat)
    func compat(_ vector: BuilderVectors.CompatCase) {
        let report = CompatibilityCheck.report(history: vector.history, proposed: vector.proposed)
        #expect(report.ok == vector.expected.ok)
        #expect(report.nextVersion == vector.expected.nextVersion)
        #expect(sorted(report.issues) == vector.expected.issues, "\(vector.name)")
        #expect(report.changes.map(sortedDetails) == vector.expected.changes, "\(vector.name)")
    }

    @Test(arguments: BuilderVectors.shared.slugs)
    func slug(_ vector: BuilderVectors.SlugCase) {
        let slug = BuilderText.slug(vector.input)
        #expect((slug.isEmpty ? "topic" : slug) == vector.expected)
    }

    @Test func whitespaceIsPydantics() {
        // The ws/ cases pin which characters the server strips; spot-check the boundary here.
        for c: Unicode.Scalar in ["\u{85}", "\u{A0}", "\u{2028}", "\u{3000}", " ", "\t"] {
            #expect(BuilderText.isWhitespace(c))
        }
        for c: Unicode.Scalar in ["\u{1C}", "\u{1F}", "\u{FEFF}", "\u{200B}", "\u{180E}"] {
            #expect(!BuilderText.isWhitespace(c))
        }
    }
}

func sorted(_ issues: [CompatibilityReport.Issue]) -> [CompatibilityReport.Issue] {
    issues.sorted {
        ($0.level.rawValue, $0.questionKey ?? "", $0.message) < ($1.level.rawValue, $1.questionKey ?? "", $1.message)
    }
}

func sortedDetails(_ c: CompatibilityReport.Change) -> CompatibilityReport.Change {
    var c = c
    c.details.sort()
    return c
}

struct BuilderVectors: Decodable {
    static let shared: BuilderVectors = {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(BuilderVectors.self, from: Fixtures.data("builder-vectors.json"))
        } catch {
            fatalError("builder-vectors.json: \(error)")
        }
    }()

    var questions: [QuestionCase]
    var compat: [CompatCase]
    var slugs: [SlugCase]

    struct QuestionCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var drafts: [DraftQuestion]
        var errors: [String]
        var testDescription: String { name }

        enum CodingKeys: String, CodingKey { case name, drafts, expected }
        struct Expected: Decodable { var errors: [String] }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            drafts = try c.decode([DraftJSON].self, forKey: .drafts).map(\.draft)
            errors = try c.decode(Expected.self, forKey: .expected).errors
        }
    }

    struct CompatCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var history: [[Question]]
        var proposed: [Question]
        var expected: Report
        var testDescription: String { name }

        enum CodingKeys: String, CodingKey { case name, history, proposed, expected }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            history = try c.decode([[QuestionJSON]].self, forKey: .history).map { $0.map(\.question) }
            proposed = try c.decode([QuestionJSON].self, forKey: .proposed).map(\.question)
            expected = try c.decode(Report.self, forKey: .expected)
        }

        struct Report: Decodable, Sendable {
            var ok: Bool
            var nextVersion: Int
            var issues: [CompatibilityReport.Issue]
            var changes: [CompatibilityReport.Change]

            enum CodingKeys: String, CodingKey {
                case ok
                case nextVersion
                case issues, changes
            }
            struct IssueJSON: Decodable {
                var level: CompatibilityReport.Level
                var questionKey: String?
                var message: String
            }
            struct ChangeJSON: Decodable {
                var kind: CompatibilityReport.ChangeKind
                var questionKey: String
                var details: [String]
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                ok = try c.decode(Bool.self, forKey: .ok)
                nextVersion = try c.decode(Int.self, forKey: .nextVersion)
                issues = try c.decode([IssueJSON].self, forKey: .issues).map {
                    .init(level: $0.level, questionKey: $0.questionKey, message: $0.message)
                }
                changes = try c.decode([ChangeJSON].self, forKey: .changes).map {
                    .init(kind: $0.kind, questionKey: $0.questionKey, details: $0.details)
                }
            }
        }
    }

    struct SlugCase: Decodable, Sendable, CustomTestStringConvertible {
        var input: String
        var expected: String
        var testDescription: String { input.isEmpty ? "(empty)" : input }
    }
}

/// A draft as the vectors spell it (the PWA's fields, constraints as text).
private struct DraftJSON: Decodable {
    var type: QuestionType
    var key, label, helpText: String
    var required: Bool
    var min, max, unit, decimals, minLength, maxLength: String
    var multiline: Bool
    var options: [Option]
    var multiple: Bool
    var minSelected, maxSelected: String

    struct Option: Decodable {
        var value, label: String
        var archived: Bool?
    }

    var draft: DraftQuestion {
        var d = DraftQuestion(type: type)
        d.key = key
        d.label = label
        d.helpText = helpText
        d.required = required
        d.min = min
        d.max = max
        d.unit = unit
        d.decimals = decimals
        d.minLength = minLength
        d.maxLength = maxLength
        d.multiline = multiline
        d.options = options.map {
            DraftOption(value: $0.value, label: $0.label, archived: $0.archived ?? false, valueEdited: true)
        }
        d.multiple = multiple
        d.minSelected = minSelected
        d.maxSelected = maxSelected
        return d
    }
}

/// A question in the API's full JSON shape. (Core stays free of DTOs; this is just for the vectors.)
private struct QuestionJSON: Decodable {
    var question: Question

    enum CodingKeys: String, CodingKey {
        case type, key, label, helpText, required, min, max, unit, decimals, minLength, maxLength, multiline,
            options, multiple, minSelected, maxSelected
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(QuestionType.self, forKey: .type)
        let kind: Question.Kind
        switch type {
        case .int:
            kind = .int(
                .init(
                    min: try c.decodeIfPresent(Int.self, forKey: .min),
                    max: try c.decodeIfPresent(Int.self, forKey: .max),
                    unit: try c.decodeIfPresent(String.self, forKey: .unit)))
        case .double:
            kind = .double(
                .init(
                    min: try c.decodeIfPresent(Double.self, forKey: .min),
                    max: try c.decodeIfPresent(Double.self, forKey: .max),
                    decimals: try c.decodeIfPresent(Int.self, forKey: .decimals),
                    unit: try c.decodeIfPresent(String.self, forKey: .unit)))
        case .str:
            kind = .string(
                .init(
                    minLength: try c.decode(Int.self, forKey: .minLength),
                    maxLength: try c.decode(Int.self, forKey: .maxLength),
                    multiline: try c.decode(Bool.self, forKey: .multiline)))
        case .enum:
            struct Option: Decodable {
                var value, label: String
                var archived: Bool
            }
            kind = .choice(
                .init(
                    options: try c.decode([Option].self, forKey: .options).map {
                        EnumOption(value: $0.value, label: $0.label, archived: $0.archived)
                    },
                    multiple: try c.decode(Bool.self, forKey: .multiple),
                    minSelected: try c.decodeIfPresent(Int.self, forKey: .minSelected),
                    maxSelected: try c.decodeIfPresent(Int.self, forKey: .maxSelected)))
        }
        question = Question(
            key: try c.decode(String.self, forKey: .key), label: try c.decode(String.self, forKey: .label),
            helpText: try c.decodeIfPresent(String.self, forKey: .helpText),
            required: try c.decode(Bool.self, forKey: .required), kind: kind)
    }
}
