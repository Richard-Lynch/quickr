import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// `shared/fixtures/home-vectors.json`: what the real `list_topics` returns for each status, sort
/// and search over a fixed set of topics at a fixed `now`. `TopicListing` must list them the same.
@Suite struct HomeVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var now: Date
            var collation: String
        }

        struct Case: Decodable, Sendable, CustomTestStringConvertible {
            var name: String
            var status: String
            var sort: String
            var q: String?
            var expected: [String]
            var testDescription: String { name }
        }

        var meta: Meta
        var topics: [TopicDetailDTO]
        var cases: [Case]
    }

    static let vectors: Vectors = {
        do {
            return try WireCoding.decoder().decode(Vectors.self, from: Fixtures.data("home-vectors.json"))
        } catch {
            fatalError("home-vectors.json: \(error)")
        }
    }()

    static var topics: [Topic] { vectors.topics.map { try! $0.toDomain() } }

    @Test(arguments: vectors.cases)
    func listsLikeTheServer(_ vector: Vectors.Case) throws {
        let status = try #require(TopicStatusFilter(rawValue: vector.status))
        let sort = try #require(TopicSort(rawValue: vector.sort))
        let listed = TopicListing.list(
            Self.topics, topic: { $0 }, now: Self.vectors.meta.now, status: status, sort: sort, query: vector.q ?? "")
        #expect(listed.map { $0.topic.id.uuidString.lowercased() } == vector.expected)
    }

    /// The device's due status equals the server's at the same instant, for every topic.
    @Test func dueMatchesTheServer() {
        let now = Self.vectors.meta.now
        for dto in Self.vectors.topics {
            let topic = try! dto.toDomain()
            #expect(TopicListing.due(of: topic, at: now) == topic.due, "\(topic.slug)")
        }
    }

    /// The file exercises what it should: every UI sort, every status, and search.
    @Test func coversEverySortAndStatus() {
        let cases = Self.vectors.cases
        #expect(Set(cases.map(\.sort)).isSuperset(of: TopicSort.allCases.map(\.rawValue)))
        #expect(Set(cases.map(\.status)) == Set(TopicStatusFilter.allCases.map(\.rawValue)))
        #expect(cases.count { ($0.q ?? "").isEmpty == false } >= 10)
        #expect(
            Self.vectors.meta.collation.hasPrefix("en_US"), "names are compared like en_US (TopicListing.nameOrder)")
    }
}
