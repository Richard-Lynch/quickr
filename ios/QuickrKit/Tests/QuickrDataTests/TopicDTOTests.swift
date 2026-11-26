import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// A topic's appearance on the wire (appearance.md §1.1, §8): `TopicDetail` and `TopicSummary`
/// always carry it, every key required, and the domain gets it; the create and the PATCH send it
/// as the server takes it.
@Suite(.timeLimit(.minutes(5))) struct TopicDTOTests {
    static func object(_ name: String) throws -> [String: Any] {
        let body = try #require(try Fixtures.api(name).body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    static func topic(_ object: [String: Any]) throws -> Topic {
        try WireCoding.decoder().decode(TopicDetailDTO.self, from: JSONSerialization.data(withJSONObject: object))
            .toDomain()
    }

    static func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(value)) as? [String: Any])
    }

    // MARK: Responses

    /// `api/getTopic.json` with its appearance: colour, emoji and tags reach `Topic`.
    @Test func getTopicDecodesWithItsAppearance() throws {
        let topic = try Self.topic(try Self.object("getTopic"))
        #expect(topic.appearance == TopicAppearance(color: .teal, icon: .emoji("🧪"), tags: ["Health"]))
    }

    /// Without one, the server sends the defaults (`null`, `null`, `[]`): the empty appearance, the
    /// default theme.
    @Test func getTopicDecodesWithoutAnAppearance() throws {
        var object = try Self.object("getTopic")
        object["appearance"] = ["color": NSNull(), "icon": NSNull(), "tags": [String]()]
        #expect(try Self.topic(object).appearance == .empty)
        #expect(try Self.topic(try Self.object("getTopic.interval")).appearance == .empty)
    }

    /// The key and each of its keys are required (`@RequiredKey`): a response that drops one fails
    /// to decode instead of reading as unthemed. `appearance: null` isn't the wire shape either.
    @Test func aMissingAppearanceKeyFailsToDecode() throws {
        let full = try Self.object("getTopic")
        var variants: [String: [String: Any]] = [:]
        var dropped = full
        dropped["appearance"] = nil
        variants["appearance"] = dropped
        var null = full
        null["appearance"] = NSNull()
        variants["appearance: null"] = null
        for key in ["color", "icon", "tags"] {
            var appearance = try #require(full["appearance"] as? [String: Any])
            appearance[key] = nil
            var variant = full
            variant["appearance"] = appearance
            variants["appearance.\(key)"] = variant
        }
        for (name, variant) in variants {
            #expect(throws: (any Error).self, "decoded without \(name)") { try Self.topic(variant) }
        }
    }

    /// An unknown colour name or icon kind fails, like an unknown schedule kind.
    @Test func anUnknownColourOrIconKindFailsToDecode() throws {
        for appearance: [String: Any] in [
            ["color": "mauve", "icon": NSNull(), "tags": [String]()],
            ["color": NSNull(), "icon": ["kind": "photo", "value": "x"], "tags": [String]()],
        ] {
            var object = try Self.object("getTopic")
            object["appearance"] = appearance
            #expect(throws: (any Error).self) { try Self.topic(object) }
        }
    }

    /// Every summary of `listTopics.all` carries its own, archived ones included.
    @Test func summariesCarryTheirAppearance() throws {
        let body = try #require(try Fixtures.api("listTopics.all").body)
        let page = try WireCoding.decoder().decode(PageDTO<TopicSummaryDTO>.self, from: body).toDomain()
        let bySlug = Dictionary(uniqueKeysWithValues: page.items.map { ($0.slug, $0.appearance) })
        #expect(bySlug["everything"] == TopicAppearance(color: .teal, icon: .emoji("🧪"), tags: ["Health"]))
        #expect(bySlug["old-habit"] == TopicAppearance(color: .amber, tags: ["Habit", "health"]))
        #expect(bySlug["water"] == .empty)
    }

    @Test func theResponseDTORoundTrips() throws {
        let appearance = TopicAppearance(color: .pink, icon: .emoji("☺️"), tags: ["a b", "Gym"])
        let dto = AppearanceDTO(appearance)
        #expect(try WireCoding.decoder().decode(AppearanceDTO.self, from: WireCoding.encoder().encode(dto)) == dto)
        #expect(dto.toDomain() == appearance)
        let empty = try Self.json(AppearanceDTO(.empty))
        #expect(empty["color"] is NSNull && empty["icon"] is NSNull && (empty["tags"] as? [String]) == [])
    }

    // MARK: Requests

    /// `TopicCreate.appearance`: all three keys when given, left out (the defaults) otherwise.
    @Test func createSendsTheAppearanceWhole() throws {
        let themed = TopicCreateDTO(
            name: "Water", questions: [], appearance: TopicAppearance(color: .blue, tags: ["Daily"]))
        let appearance = try #require(try Self.json(themed)["appearance"] as? [String: Any])
        #expect(appearance["color"] as? String == "blue")
        #expect(appearance["icon"] is NSNull)
        #expect(appearance["tags"] as? [String] == ["Daily"])
        #expect(try Self.json(TopicCreateDTO(name: "Water", questions: []))["appearance"] == nil)
    }

    /// `AppearanceUpdate`'s PATCH semantics on the wire: omitted is unchanged, `null` clears,
    /// `tags: []` clears; no appearance leaves the key out (`appearance: null` is a 422).
    @Test func thePatchIsThreeStatePerField() throws {
        let encoder = WireCoding.encoder()
        func text(_ update: TopicUpdateDTO) throws -> String {
            String(decoding: try encoder.encode(update), as: UTF8.self)
        }
        #expect(try text(TopicUpdateDTO(name: "x")) == #"{"name":"x"}"#)
        let cleared = AppearanceUpdateDTO(AppearanceUpdate(color: .some(nil), icon: .some(nil), tags: []))
        #expect(
            try text(TopicUpdateDTO(appearance: cleared)) == #"{"appearance":{"color":null,"icon":null,"tags":[]}}"#)
        let colourOnly = AppearanceUpdateDTO(AppearanceUpdate(color: .some(.red)))
        #expect(try text(TopicUpdateDTO(appearance: colourOnly)) == #"{"appearance":{"color":"red"}}"#)
        let icon = AppearanceUpdateDTO(AppearanceUpdate(icon: .some(.emoji("🚬"))))
        #expect(
            try text(TopicUpdateDTO(appearance: icon, expectedRevision: 4))
                == #"{"appearance":{"icon":{"kind":"emoji","value":"🚬"}},"expected_revision":4}"#)
        for update in [TopicUpdateDTO(appearance: cleared), TopicUpdateDTO(appearance: colourOnly)] {
            #expect(try WireCoding.decoder().decode(TopicUpdateDTO.self, from: encoder.encode(update)) == update)
        }
    }

    /// The Details save is one PATCH: the changed details and appearance together, with
    /// `expected_revision` when the screen gives it (``TopicRequests/details(_:expectedRevision:)``).
    @Test func theDetailsSaveCarriesTheAppearance() throws {
        let change = TopicDetailsChange(
            name: "Smoke", appearance: AppearanceUpdate(color: .some(.amber), tags: ["Habit"]))
        let body = try Self.json(TopicRequests.details(change, expectedRevision: 7))
        #expect(body["name"] as? String == "Smoke")
        #expect(body["expected_revision"] as? Int == 7)
        let appearance = try #require(body["appearance"] as? [String: Any])
        #expect(Set(appearance.keys) == ["color", "tags"])
        #expect(try Self.json(TopicRequests.details(TopicDetailsChange(name: "x")))["appearance"] == nil)
        #expect(try Self.json(TopicRequests.details(TopicDetailsChange(name: "x")))["expected_revision"] == nil)
    }

    /// Create leaves an empty appearance out, so the request goldens of an unthemed create stay put.
    @Test func createWithoutAnAppearanceLeavesItOut() throws {
        var draft = TopicDraft.empty()
        draft.setName("Morning")
        draft.timed = true
        draft.setStepLabel(draft.addStep(), "Shower")
        let creation = try draft.validatedForCreation().get()
        #expect(TopicRequests.create(creation, schedule: nil).appearance == nil)
        let themed = TopicAppearance(icon: .emoji("💧"))
        #expect(TopicRequests.create(creation, schedule: nil, appearance: themed).appearance == themed)
    }
}
