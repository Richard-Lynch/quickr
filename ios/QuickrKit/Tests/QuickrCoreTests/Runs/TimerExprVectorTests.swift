import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// R13 (timers2.md §2.5, §12.3): Swift/Python parity for alert expressions. Every case in
/// shared/fixtures/timer-expr-vectors.json (generated from backend/app/services/timer_expr.py by
/// `make vectors`) gives the same whole ms, or the same error code at the same `pos`, here. One
/// test walks every case, so none can be filtered out or skipped.
@Suite struct TimerExprVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var generatorVersion: Int
            var maxMs: Int
            var maxLength: Int

            enum CodingKeys: String, CodingKey {
                case generatorVersion = "generator_version"
                case maxMs = "max_ms"
                case maxLength = "max_length"
            }
        }

        struct Expected: Decodable, Equatable {
            var ms: Int?
            var error: String?
            var pos: Int?
        }

        struct Case: Decodable {
            var name: String
            var expr: String
            var variables: [String: Int]
            var expected: Expected
        }

        var meta: Meta
        var cases: [Case]
    }

    static func load() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Fixtures.data("timer-expr-vectors.json"))
    }

    @Test func casesHaveUniqueNamesAndTheSameLimits() throws {
        let vectors = try Self.load()
        #expect(vectors.meta.generatorVersion == 1)
        #expect(vectors.cases.count >= 40)
        #expect(Set(vectors.cases.map(\.name)).count == vectors.cases.count)
        #expect(vectors.meta.maxMs == TimerExpr.maxMs)
        #expect(vectors.meta.maxLength == TimerExpr.maxLength)
        // timers2.md §2.5's minimum list.
        for name in [
            "plain_seconds", "minutes_fraction", "user_half_spaced", "user_alert1_uppercase", "user_parens",
            "division_truncates", "fractional_ms_truncates", "unit_uppercase_is_syntax", "bare_number",
            "duration_plus_number", "div_zero_expression", "too_long_text", "too_long_intermediate",
            "syntax_space_before_unit", "syntax_empty", "two_variables", "zero_allowed",
        ] {
            #expect(vectors.cases.contains { $0.name == name }, "missing case \(name)")
        }
    }

    @Test func everyCaseMatchesTheReference() throws {
        let vectors = try Self.load()
        var ran: [String] = []
        for c in vectors.cases {
            let got: Vectors.Expected
            do {
                got = Vectors.Expected(ms: try TimerExpr.evaluate(c.expr, variables: c.variables))
            } catch {
                got = Vectors.Expected(error: error.code.rawValue, pos: error.pos)
                // The 422 message of timers2.md §1.3.
                #expect(error.description.hasPrefix("\(error.code.rawValue) at \(error.pos): "), "\(c.name)")
            }
            #expect(got == c.expected, "\(c.name): \(c.expr)")
            ran.append(c.name)
        }
        #expect(ran == vectors.cases.map(\.name), "every case ran")
    }

    @Test func positionsCountCodePoints() {
        // An emoji is one code point (two UTF-16 units): the unknown character is at 4.
        do {
            _ = try TimerExpr.evaluate("30s+😀", variables: [:])
            Issue.record("evaluated")
        } catch {
            #expect(error.code == .syntax)
            #expect(error.pos == 4)
        }
    }
}
