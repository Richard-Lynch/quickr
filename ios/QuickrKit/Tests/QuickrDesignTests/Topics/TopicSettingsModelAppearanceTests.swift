import Foundation
import QuickrCore
import QuickrUI
import Testing

/// The Appearance row of topic settings (appearance.md §7): saved with the details, only the
/// changed fields, with the revision on screen.
extension TopicSettingsModelTests {
    static let saved = TopicAppearance(color: .teal, icon: .emoji("🚬"), tags: ["Gym", "run"])

    func themed(saved: TopicAppearance = Self.saved) -> TopicSettingsModel {
        TopicSettingsModel(
            topic: Self.topic, writer: writer, toasts: toasts, deviceTimeZone: "Europe/London",
            appearanceSaver: writer, savedAppearance: saved)
    }

    func add(_ tag: String, to model: TopicSettingsModel) {
        model.appearance.newTag = tag
        model.addTag()
    }

    @Test func theEditorStartsFromTheSavedAppearance() {
        let model = themed()
        #expect(model.editsAppearance)
        #expect(model.appearance == AppearanceDraft(Self.saved))
        #expect(model.appearance.icon == "🚬")
        #expect(!model.detailsDirty)
        model.appearance.color = .pink
        #expect(model.appearanceDirty && model.detailsDirty)
    }

    @Test func clearingTheIconSendsIconNullWithTheRevision() async {
        let model = themed()
        model.appearance.icon = ""
        await model.saveDetails()
        #expect(writer.calls == [.appearance(AppearanceUpdate(icon: .some(nil)), baseRevision: 3)])
        #expect(titles == ["Saved"])
        #expect(model.savedAppearance == TopicAppearance(color: .teal, icon: nil, tags: ["Gym", "run"]))
        #expect(!model.detailsDirty)
    }

    @Test func onlyTheChangedFieldsAreSent() async {
        let model = themed()
        model.appearance.color = nil
        model.removeTag(at: 1)
        await model.saveDetails()
        #expect(writer.calls == [.appearance(AppearanceUpdate(color: .some(nil), tags: ["Gym"]), baseRevision: 3)])
    }

    @Test func clearingEveryTagSendsAnEmptyList() async {
        let model = themed()
        model.removeTag(at: 0)
        model.removeTag(at: 0)
        await model.saveDetails()
        #expect(writer.calls == [.appearance(AppearanceUpdate(tags: []), baseRevision: 3)])
    }

    @Test func detailsThenAppearanceEachWithTheLatestRevision() async {
        let model = themed()
        model.name = "Feelings"
        model.appearance.icon = "☺"
        await model.saveDetails()
        #expect(
            writer.calls == [
                .details(TopicDetailsChange(name: "Feelings")),
                // The details save moved the topic to revision 4.
                .appearance(AppearanceUpdate(icon: .some(.emoji("☺\u{FE0F}"))), baseRevision: 4),
            ])
        #expect(model.topic.revision == 5)
        #expect(model.appearance.icon == "☺\u{FE0F}", "reopens from the stored form")
        #expect(titles == ["Saved"])
    }

    @Test func theSameAppearanceIsNothingToSave() async {
        let model = themed()
        model.appearance.tags = ["Gym", "run"]
        model.appearance.icon = "🚬"
        await model.saveDetails()
        #expect(writer.calls.isEmpty)
        #expect(titles == ["Nothing to save"])
    }

    @Test func aDuplicateOrEleventhTagIsRefusedBeforeSaving() async {
        let model = themed()
        add("GYM", to: model)
        #expect(model.appearanceErrors[.newTag] == AppearanceMessage.tagDuplicate("GYM"))
        for i in 3...10 { add("t\(i)", to: model) }
        #expect(model.appearance.tags.count == 10)
        add("t11", to: model)
        #expect(model.appearanceErrors[.newTag] == AppearanceMessage.tooManyTags(10))
        #expect(model.appearance.tags.count == 10)
        // A list edited past the rules some other way is still refused on save, on its field.
        model.appearance.tags.append("t11")
        await model.saveDetails()
        #expect(model.appearanceErrors[.tags] == AppearanceMessage.tooManyTags(10))
        #expect(writer.calls.isEmpty)
    }

    @Test func anInvalidEmojiStaysLocal() async {
        let model = themed()
        model.appearance.icon = "5\u{FE0F}"
        await model.saveDetails()
        #expect(writer.calls.isEmpty)
        #expect(model.appearanceErrors[.icon] == AppearanceMessage.iconText)
    }

    @Test func aStaleRevisionSaysSoAndKeepsTheEdit() async {
        let model = themed()
        writer.appearanceResult = .staleRevision
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(model.detailsBanner == TopicWriteMessage.staleRevision)
        #expect(model.appearance.color == .pink)
        #expect(model.savedAppearance == Self.saved)
    }

    @Test func serverAppearanceErrorsLandOnTheirFields() async {
        let model = themed()
        writer.appearanceResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "Request validation failed",
                errors: [FieldIssue(location: NewTopicModelTests.appearancePath(.key("tags"), .index(0)), message: "x")]
            ))
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(model.appearanceErrors[.tag(0)] == "X")
        #expect(model.detailsBanner == nil, "every issue is on a field")
    }

    @Test func aNewSlugMovesTheScreenEvenWhenTheAppearanceIsRefused() async {
        let slugs = Log()
        let model = TopicSettingsModel(
            topic: Self.topic, writer: writer, toasts: toasts, deviceTimeZone: "Europe/London",
            onSlugChanged: { slugs.values.append($0) }, appearanceSaver: writer, savedAppearance: Self.saved)
        writer.appearanceResult = .offline
        model.slug = "feelings"
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(slugs.values == ["feelings"])
        #expect(model.detailsBanner == TopicWriteMessage.offline)
        #expect(model.appearance.color == .pink)
    }
}
