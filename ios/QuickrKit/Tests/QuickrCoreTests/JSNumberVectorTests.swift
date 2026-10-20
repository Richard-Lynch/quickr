import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// Differential check of `JSNumber.string` against V8: shared/fixtures/jsnumber-vectors.json
/// (frontend/scripts/gen-jsnumber-vectors.js) holds `String(x)` for a few thousand doubles,
/// random bit patterns, powers of ten and typed-looking decimals among them.
@Suite(.timeLimit(.minutes(2))) struct JSNumberVectorTests {
    struct Vectors: Decodable {
        struct Case: Decodable {
            var bits: String
            var string: String
        }

        var cases: [Case]
    }

    @Test func matchesJavaScriptString() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Fixtures.data("jsnumber-vectors.json"))
        #expect(vectors.cases.count > 5000)
        var mismatches: [String] = []
        for vector in vectors.cases {
            let bits = try #require(UInt64(vector.bits, radix: 16), "\(vector.bits)")
            let actual = JSNumber.string(Double(bitPattern: bits))
            if actual != vector.string { mismatches.append("\(vector.bits): \(actual) != \(vector.string)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(20))")
    }
}
