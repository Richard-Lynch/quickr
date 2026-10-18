import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// Every case in shared/fixtures/answer-text-vectors.json (generated from the server's
/// services/answers.py; the PWA asserts the same cases): acceptance, the stored value, and the
/// message.
@Suite(.timeLimit(.minutes(2))) struct AnswerTextVectorTests {
    @Test func hasCases() {
        #expect(AnswerTextVectors.shared.cases.count > 150)
    }

    @Test func whitespaceIsPythons() {
        let python = Set(AnswerTextVectors.shared.pythonWhitespace)
        for value in UInt32(0)...0x3000 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            #expect(ServerText.isWhitespace(scalar) == python.contains(value), "U+\(String(value, radix: 16))")
        }
    }

    @Test(arguments: AnswerTextVectors.shared.cases)
    func answer(_ vector: AnswerTextVectors.Case) {
        let result = AnswerValidator.validate(vector.question, vector.input)
        switch (result, vector.expected) {
        case (.success(let value), .accepted(let expected)):
            #expect(value == expected)
        case (.failure(let message), .rejected(let expected)):
            #expect(message.message == expected)
        default:
            Issue.record("got \(result), expected \(vector.expected)")
        }
    }
}

struct AnswerTextVectors: Decodable {
    static let shared: AnswerTextVectors = {
        do {
            return try JSONDecoder().decode(AnswerTextVectors.self, from: Fixtures.data("answer-text-vectors.json"))
        } catch {
            fatalError("answer-text-vectors.json: \(error)")
        }
    }()

    var cases: [Case]
    var pythonWhitespace: [UInt32]

    enum CodingKeys: String, CodingKey {
        case cases, meta
    }

    enum MetaKeys: String, CodingKey {
        case pythonWhitespace = "python_whitespace"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cases = try container.decode([Case].self, forKey: .cases)
        pythonWhitespace = try container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
            .decode([UInt32].self, forKey: .pythonWhitespace)
    }

    static func string(_ codePoints: [UInt32]) -> String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: codePoints.compactMap(Unicode.Scalar.init))
        return String(s)
    }

    enum Expected: Sendable, CustomStringConvertible {
        case accepted(AnswerValue?)
        case rejected(String)

        var description: String {
            switch self {
            case .accepted(let value): "accepted \(String(describing: value))"
            case .rejected(let message): "rejected \"\(message)\""
            }
        }
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var question: Question
        var input: AnswerInput
        var expected: Expected

        enum CodingKeys: String, CodingKey {
            case name, question, raw, expected
        }

        enum ExpectedKeys: String, CodingKey {
            case ok, value, message
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            question = try c.decode(VectorQuestion.self, forKey: .question).question
            if let items = try? c.decode([[UInt32]].self, forKey: .raw) {
                input = .selection(items.map(AnswerTextVectors.string))
            } else {
                input = .text(AnswerTextVectors.string(try c.decode([UInt32].self, forKey: .raw)))
            }
            let e = try c.nestedContainer(keyedBy: ExpectedKeys.self, forKey: .expected)
            if try e.decode(Bool.self, forKey: .ok) {
                if let list = try? e.decode([[UInt32]].self, forKey: .value) {
                    expected = .accepted(.strings(list.map(AnswerTextVectors.string)))
                } else if let value = try e.decodeIfPresent([UInt32].self, forKey: .value) {
                    expected = .accepted(.string(AnswerTextVectors.string(value)))
                } else {
                    expected = .accepted(nil)
                }
            } else {
                expected = .rejected(try e.decode(String.self, forKey: .message))
            }
        }

        var testDescription: String { name }
    }
}
