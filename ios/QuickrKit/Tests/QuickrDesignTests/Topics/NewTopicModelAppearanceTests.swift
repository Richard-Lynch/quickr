import Foundation
import QuickrCore
import QuickrUI
import Testing

/// The Appearance row of a new topic (appearance.md §7): tags refused as the server would, and the
/// appearance sent with the create.
extension NewTopicModelTests {
    func themed() -> NewTopicModel {
        NewTopicModel(writer: writer, toasts: toasts, deviceTimeZone: "Europe/London", appearanceSaver: writer)
    }

    func add(_ tag: String, to model: NewTopicModel) {
        model.appearance.newTag = tag
        model.addTag()
    }

    static func appearancePath(_ rest: FieldIssue.PathComponent...) -> [FieldIssue.PathComponent] {
        [.key("body"), .key("appearance")] + rest
    }

    @Test func noSaverNoAppearanceRow() {
        #expect(!model.editsAppearance)
        #expect(themed().editsAppearance)
    }

    @Test func aTagIsAddedInItsStoredForm() {
        let model = themed()
        add("  morning   run ", to: model)
        #expect(model.appearance.tags == ["morning run"])
        #expect(model.appearance.newTag.isEmpty)
        #expect(model.appearanceErrors.isEmpty)
        #expect(model.hasUnsavedChanges)
    }

    @Test func aDuplicateTagIsRefusedCasefolded() {
        let model = themed()
        add("Gym", to: model)
        add(" GYM ", to: model)
        #expect(model.appearance.tags == ["Gym"])
        #expect(model.appearance.newTag == " GYM ", "the typed text stays to fix")
        #expect(model.appearanceErrors[.newTag] == AppearanceMessage.tagDuplicate("GYM"))
        // Fixing it clears the error on the next add.
        add("run", to: model)
        #expect(model.appearance.tags == ["Gym", "run"])
        #expect(model.appearanceErrors[.newTag] == nil)
    }

    @Test func anEleventhTagIsRefused() {
        let model = themed()
        for i in 1...10 { add("t\(i)", to: model) }
        #expect(model.appearance.tags.count == 10)
        add("t11", to: model)
        #expect(model.appearance.tags.count == 10)
        #expect(model.appearanceErrors[.newTag] == AppearanceMessage.tooManyTags(10))
        model.removeTag(at: 0)
        add("t11", to: model)
        #expect(model.appearance.tags == (2...11).map { "t\($0)" })
    }

    @Test func createSendsTheAppearanceInItsStoredForm() async {
        let model = themed()
        model.draft.setName("Water")
        model.appearance.color = .teal
        model.appearance.icon = "☺"
        add("Gym", to: model)
        await model.create()
        #expect(
            writer.calls == [
                .createWithAppearance(
                    name: "Water", appearance: TopicAppearance(color: .teal, icon: .emoji("☺\u{FE0F}"), tags: ["Gym"]))
            ])
        #expect(toasts.items.map(\.toast.title) == ["Topic created"])
    }

    @Test func noAppearanceIsSentAsTheDefaults() async {
        let model = themed()
        model.draft.setName("Water")
        await model.create()
        #expect(writer.calls == [.createWithAppearance(name: "Water", appearance: .empty)])
    }

    @Test func anInvalidEmojiIsNotSentAndRevalidatesAsItIsFixed() async {
        let model = themed()
        model.draft.setName("Water")
        model.appearance.icon = "ab"
        #expect(model.appearance.iconError() == AppearanceMessage.iconNotOne, "shown as it is typed")
        await model.create()
        #expect(writer.calls.isEmpty)
        #expect(model.appearanceErrors[.icon] == AppearanceMessage.iconNotOne)
        #expect(model.visibleBanner == NewTopicModel.clientInvalid)
        model.appearance.icon = "🚬"
        #expect(model.appearanceErrors.isEmpty)
        #expect(model.visibleBanner == nil)
    }

    @Test func serverAppearanceErrorsLandOnTheirFields() async {
        let model = themed()
        model.draft.setName("Water")
        add("Gym", to: model)
        add("run", to: model)
        writer.topicResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "Request validation failed",
                errors: [
                    FieldIssue(location: Self.appearancePath(.key("tags"), .index(1)), message: "bad tag"),
                    FieldIssue(location: Self.appearancePath(.key("icon"), .key("value")), message: "no"),
                ]))
        await model.create()
        #expect(model.appearanceErrors[.tag(1)] == "Bad tag")
        #expect(model.appearanceErrors[.icon] == "No")
        #expect(model.bannerDetails.isEmpty, "placed, not listed")
        // After a Create, an edit revalidates locally, as the builder's fields do.
        model.removeTag(at: 0)
        #expect(model.appearanceErrors.isEmpty)
    }
}
