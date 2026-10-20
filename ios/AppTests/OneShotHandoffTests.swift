import Testing

@testable import QuickR

/// The slug-save handoff (`TopicSettingsHandoff`): the new screen gets the same model, once, and
/// only for the same store and topic.
@MainActor @Suite struct OneShotHandoffTests {
    final class Model {
        let topic: String
        init(_ topic: String) { self.topic = topic }
    }

    @Test func theNextScreenGetsTheSameModelOnce() {
        let handoff = OneShotHandoff<Model, Int>()
        let model = Model("mood")
        handoff.put(model, scope: 1)
        #expect(handoff.take(scope: 1) { $0.topic == "mood" } === model)
        #expect(handoff.take(scope: 1) { $0.topic == "mood" } == nil, "one-shot")
    }

    @Test func anotherStoreOrTopicDoesntTakeIt() {
        let handoff = OneShotHandoff<Model, Int>()
        let model = Model("mood")
        handoff.put(model, scope: 1)
        #expect(handoff.take(scope: 2) { _ in true } == nil, "another store")
        #expect(handoff.take(scope: 1) { $0.topic == "water" } == nil, "another topic")
        #expect(handoff.take(scope: 1) { $0.topic == "mood" } === model, "still there for the right one")
    }

    @Test func aLaterPutReplacesAnUntakenOne() {
        let handoff = OneShotHandoff<Model, Int>()
        handoff.put(Model("mood"), scope: 1)
        let newer = Model("water")
        handoff.put(newer, scope: 1)
        #expect(handoff.take(scope: 1) { $0.topic == "mood" } == nil)
        #expect(handoff.take(scope: 1) { $0.topic == "water" } === newer)
    }
}
