import Foundation
import QuickrCore
import QuickrData
import Testing

/// The topic screens' request bodies, as the PWA's `NewTopicPage` and `SettingsPage` build them.
/// (`RequestGoldenTests` pins the DTOs' wire form against `shared/fixtures/requests`.)
@Suite struct TopicRequestsTests {
    static let topic = Topic(
        id: UUID(), slug: "mood", name: "Mood", description: "How do you feel", currentVersion: 1, revision: 4,
        questionCount: 1, createdAt: .distantPast, updatedAt: .distantPast,
        questions: [Question(key: "mood", label: "Mood", kind: .int(.init(min: 1, max: 5)))])

    static func encoded(_ body: TopicUpdateDTO) throws -> [String: Any] {
        let data = try WireCoding.encoder().encode(body)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func details(name: String = "Mood", slug: String = "mood", description: String = "How do you feel") throws
        -> TopicDraft.Details
    {
        try TopicDraft.editing(name: name, slug: slug, description: description, questions: topic.questions)
            .validatedDetails().get()
    }

    @Test func unchangedDetailsHaveNothingToSave() throws {
        #expect(TopicDetailsChange(try Self.details(), from: Self.topic) == nil)
    }

    @Test func surroundingWhitespaceAloneIsNoChange() throws {
        #expect(TopicDetailsChange(try Self.details(name: "  Mood ", slug: " mood"), from: Self.topic) == nil)
    }

    @Test func onlyChangedDetailsAreSent() throws {
        let body = TopicRequests.details(
            try #require(TopicDetailsChange(try Self.details(name: "Feelings"), from: Self.topic)))
        #expect(try Self.encoded(body).keys.sorted() == ["name"])
        #expect(body.name == "Feelings")

        let both = TopicRequests.details(
            try #require(TopicDetailsChange(try Self.details(slug: "feelings", description: ""), from: Self.topic)))
        #expect(try Self.encoded(both).keys.sorted() == ["description", "slug"])
        #expect(both.expectedRevision == nil)
    }

    @Test func aScheduleSaveSendsItAndARemovalSendsNull() throws {
        let daily = Schedule.daily(.init(times: [TimeOfDay("08:00")!], timezone: "UTC"))
        let set = try Self.encoded(TopicRequests.schedule(daily))
        #expect(set.keys.sorted() == ["schedule"])
        #expect((set["schedule"] as? [String: Any])?["kind"] as? String == "daily")

        let cleared = try Self.encoded(TopicRequests.schedule(nil))
        #expect(cleared.keys.sorted() == ["schedule"])
        #expect(cleared["schedule"] is NSNull)
    }

    @Test func createCarriesTheDraftAndTheSchedule() throws {
        var draft = TopicDraft.empty()
        draft.setName("Water")
        let id = draft.addQuestion(.int)
        draft.setLabel(id, "Glasses")
        let creation = try draft.validatedForCreation().get()
        let interval = Schedule.interval(.init(everyMinutes: 120, timezone: "Europe/London"))
        let body = TopicRequests.create(creation, schedule: interval)
        #expect(body.name == "Water")
        #expect(body.slug == creation.slug)
        #expect(body.questions.count == 1)
        #expect(body.schedule == ScheduleInputDTO(interval))
        #expect(TopicRequests.create(creation, schedule: nil).schedule == nil)
    }
}
