import Foundation
import QuickrCore
import Testing

@testable import QuickR

/// The slug-save handoff (Codex r2): the Router hands a model only to the screen at the replaced
/// path entry, once, and drops it when that entry leaves; the screen takes it only for the same
/// topic id in the same store.
@MainActor @Suite struct RouteCarryTests {
    final class Model {}

    static let mood = Route.topicSettings(TopicLinkRef("mood")!)
    static let feelings = Route.topicSettings(TopicLinkRef("feelings")!)
    static let home = Route.topic(TopicLinkRef("mood")!, .entries)

    func router(_ path: [Route]) -> Router {
        let router = Router()
        router.path = path
        return router
    }

    @Test func theReplacingScreenTakesItOnce() {
        let router = router([Self.home, Self.mood])
        let model = Model()
        router.replaceTop(with: Self.feelings, carrying: model)
        #expect(router.path == [Self.home, Self.feelings])
        #expect(router.takeCarried(for: Self.feelings) === model)
        #expect(router.takeCarried(for: Self.feelings) == nil, "once")
    }

    @Test func anotherRouteDoesntTakeIt() {
        let router = router([Self.mood])
        router.replaceTop(with: Self.feelings, carrying: Model())
        #expect(router.takeCarried(for: Self.mood) == nil)
    }

    @Test func itIsDroppedWhenTheEntryLeavesThePath() {
        let router = router([Self.home, Self.mood])
        router.replaceTop(with: Self.feelings, carrying: Model())
        router.path.removeLast()  // Back
        router.path.append(Self.feelings)  // the same link, opened again later
        #expect(router.takeCarried(for: Self.feelings) == nil, "a later screen never gets it")
    }

    @Test func itIsDroppedWhenTheEntryIsReplacedAgain() {
        let router = router([Self.mood])
        router.replaceTop(with: Self.feelings, carrying: Model())
        router.replaceTop(with: Self.home)
        router.path = [Self.feelings]
        #expect(router.takeCarried(for: Self.feelings) == nil)
    }

    @Test func aScreenPushedOnTopCantTakeIt() {
        let router = router([Self.mood])
        router.replaceTop(with: Self.feelings, carrying: Model())
        router.open(Self.feelings)  // the same route again, one deeper
        #expect(router.takeCarried(for: Self.feelings) == nil)
    }

    @Test func theModelIsForTheSameTopicIdInTheSameStoreOnly() {
        let model = Model()
        let id = UUID()
        let carried = CarriedModel(model, id: id, scope: 1)
        #expect(carried.model(for: id, scope: 1) === model)
        #expect(carried.model(for: UUID(), scope: 1) == nil, "the slug now names another topic")
        #expect(carried.model(for: id, scope: 2) == nil, "another store")
    }
}
