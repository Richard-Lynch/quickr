import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// `shared/fixtures/entries-vectors.json`: what the real `list_entries` returns for each filter
/// over one topic's entries, and `topic_stats`'s source order. `EntryListing` must agree.
@Suite struct EntryVectorTests {
    struct Vectors: Decodable {
        struct Filters: Decodable, Sendable {
            var capturedFrom: Date?
            var version: Int?
            var source: String?

            enum CodingKeys: String, CodingKey {
                case capturedFrom = "captured_from"
                case version
                case source
            }
        }

        struct Case: Decodable, Sendable, CustomTestStringConvertible {
            var name: String
            var filters: Filters
            var expected: [String]
            var testDescription: String { name }
        }

        struct Source: Decodable, Sendable {
            var value: String
            var count: Int
        }

        var entries: [EntryDTO]
        var cases: [Case]
        var sources: [Source]
    }

    static let vectors: Vectors = {
        do {
            return try WireCoding.decoder().decode(Vectors.self, from: Fixtures.data("entries-vectors.json"))
        } catch {
            fatalError("entries-vectors.json: \(error)")
        }
    }()

    static var entries: [Entry] { vectors.entries.map { try! $0.toDomain() } }

    @Test(arguments: vectors.cases)
    func listsLikeTheServer(_ vector: Vectors.Case) {
        let listed = EntryListing.list(
            Self.entries, entry: { $0 }, capturedFrom: vector.filters.capturedFrom, version: vector.filters.version,
            source: vector.filters.source)
        #expect(listed.map { $0.id.uuidString.lowercased() } == vector.expected)
    }

    @Test func sourcesInTheServersOrder() {
        let sources = EntryListing.sources(Self.entries)
        #expect(sources.map(\.value) == Self.vectors.sources.map(\.value))
        #expect(sources.map(\.count) == Self.vectors.sources.map(\.count))
    }

    /// The file exercises what it should: equal capture times, every filter, offsets.
    @Test func coversTiesAndEveryFilter() {
        let times = Self.entries.map(\.capturedAt)
        #expect(Set(times).count < times.count, "entries share a captured_at")
        let cases = Self.vectors.cases
        #expect(cases.contains { $0.filters.capturedFrom != nil })
        #expect(cases.contains { $0.filters.version != nil })
        #expect(cases.contains { $0.filters.source != nil })
        #expect(cases.contains { $0.expected.isEmpty })
    }
}
