import Foundation
import QuickrCore
import Testing

@testable import QuickrData

@Suite struct TopicEntityQueryTests {
    let topics: [ViewTopic]

    init() async throws {
        topics = try await PlaceholderTopicRepository().topics()
    }

    @Test func listsActiveTopicsInOrder() {
        #expect(TopicEntityQuery.listed(topics).map(\.name) == ["Coffee", "Mood"])
    }

    @Test func resolvesIdsIncludingArchivedAndSkipsUnknown() {
        let ids = [PlaceholderTopicRepository.oldHabit, UUID(), PlaceholderTopicRepository.coffee]
        #expect(TopicEntityQuery.entities(for: ids, in: topics).map(\.name) == ["Old habit", "Coffee"])
    }

    @Test(arguments: [("cof", ["Coffee"]), ("MOOD", ["Mood"]), ("  ", ["Coffee", "Mood"]), ("habit", [])])
    func matchesNameOrSlugAmongActiveTopics(query: String, expected: [String]) {
        #expect(TopicEntityQuery.entities(matching: query, in: topics).map(\.name) == expected)
    }

    @Test func entityCarriesTheTopicIdentity() {
        let entity = TopicEntity(topics[0].topic)
        #expect(entity.id == PlaceholderTopicRepository.coffee)
        #expect(entity.slug == "coffee")
    }
}

/// The query through the registered repository, as the system calls it in the app or the widget.
@Test func queryReadsTheRegisteredSource() async throws {
    IntentTopicSource.register(PlaceholderTopicRepository())
    let query = TopicEntityQuery()
    #expect(try await query.allEntities().map(\.name) == ["Coffee", "Mood"])
    #expect(try await query.entities(for: [PlaceholderTopicRepository.mood]).map(\.name) == ["Mood"])
}

@Test func logEntryStubReturnsTheTopicWithoutWriting() async throws {
    let intent = LogEntryIntent(topic: TopicEntity(id: PlaceholderTopicRepository.coffee, name: "Coffee", slug: "coffee"))
    _ = try await intent.perform()
}
