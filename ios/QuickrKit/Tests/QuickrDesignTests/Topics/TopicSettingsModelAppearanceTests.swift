import Foundation
import QuickrCore
import QuickrUI
import Testing

/// The Appearance row of topic settings (appearance.md §7): saved with the details, only the
/// changed fields, with the revision on screen.
extension TopicSettingsModelTests {
    static let saved = TopicAppearance(color: .teal, icon: .emoji("🚬"), tags: ["Gym", "run"])

    /// A model over a topic (and a server copy) with `saved` as its appearance.
    func themed(saved: TopicAppearance = Self.saved) -> TopicSettingsModel {
        var topic = Self.topic
        topic.appearance = saved
        writer.server = topic
        return TopicSettingsModel(topic: topic, writer: writer, toasts: toasts, deviceTimeZone: "Europe/London")
    }

    func add(_ tag: String, to model: TopicSettingsModel) {
        model.appearance.newTag = tag
        model.addTag()
    }

    @Test func theEditorStartsFromTheSavedAppearance() {
        let model = themed()
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
        #expect(
            writer.calls == [
                .details(TopicDetailsChange(appearance: AppearanceUpdate(icon: .some(nil))), expectedRevision: 3)
            ])
        #expect(titles == ["Saved"])
        #expect(model.topic.appearance == TopicAppearance(color: .teal, icon: nil, tags: ["Gym", "run"]))
        #expect(!model.detailsDirty)
    }

    @Test func onlyTheChangedFieldsAreSent() async {
        let model = themed()
        model.appearance.color = nil
        model.removeTag(at: 1)
        await model.saveDetails()
        #expect(
            writer.calls == [
                .details(
                    TopicDetailsChange(appearance: AppearanceUpdate(color: .some(nil), tags: ["Gym"])),
                    expectedRevision: 3)
            ])
    }

    @Test func clearingEveryTagSendsAnEmptyList() async {
        let model = themed()
        model.removeTag(at: 0)
        model.removeTag(at: 0)
        await model.saveDetails()
        #expect(
            writer.calls == [.details(TopicDetailsChange(appearance: AppearanceUpdate(tags: [])), expectedRevision: 3)])
    }

    /// One PATCH carries the details and the appearance, with the revision on screen.
    @Test func detailsAndAppearanceGoInOnePatch() async {
        let model = themed()
        model.name = "Feelings"
        model.appearance.icon = "☺"
        await model.saveDetails()
        let change = TopicDetailsChange(
            name: "Feelings", appearance: AppearanceUpdate(icon: .some(.emoji("☺\u{FE0F}"))))
        #expect(writer.calls == [.details(change, expectedRevision: 3)])
        #expect(model.topic.revision == 4)
        #expect(model.topic.appearance.icon == .emoji("☺\u{FE0F}"))
        #expect(model.appearance.icon == "☺\u{FE0F}", "reopens from the stored form")
        #expect(!model.detailsDirty)
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
        model.appearance.newTag = ""
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
        writer.topicResult = .staleRevision
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(model.detailsBanner == TopicWriteMessage.staleRevision)
        #expect(model.appearance.color == .pink)
        #expect(model.topic.appearance == Self.saved)
    }

    @Test func serverAppearanceErrorsLandOnTheirFields() async {
        let model = themed()
        writer.topicResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "Request validation failed",
                errors: [FieldIssue(location: NewTopicModelTests.appearancePath(.key("tags"), .index(0)), message: "x")]
            ))
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(model.appearanceErrors[.tag(0)] == "X")
        #expect(model.detailsBanner == nil, "every issue is on a field")
    }

    @Test func aRefusedSaveKeepsBothHalvesAndTheSlug() async {
        let slugs = Log()
        var topic = Self.topic
        topic.appearance = Self.saved
        let model = TopicSettingsModel(
            topic: topic, writer: writer, toasts: toasts, deviceTimeZone: "Europe/London",
            onSlugChanged: { slugs.values.append($0) })
        writer.topicResult = .offline
        model.slug = "feelings"
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(slugs.values.isEmpty)
        #expect(model.detailsBanner == TopicWriteMessage.offline)
        #expect(model.slug == "feelings" && model.appearance.color == .pink)
    }

    @Test func aNewSlugWithTheAppearanceMovesTheScreen() async {
        let slugs = Log()
        let model = TopicSettingsModel(
            topic: Self.topic, writer: writer, toasts: toasts, deviceTimeZone: "Europe/London",
            onSlugChanged: { slugs.values.append($0) })
        model.slug = "feelings"
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(slugs.values == ["feelings"])
        #expect(model.topic.appearance.color == .pink)
    }

    /// A sync that changes the appearance elsewhere reopens the editor from it.
    @Test func aNewerAppearanceResetsTheEditor() {
        let model = themed()
        var newer = model.topic
        newer.appearance.tags = ["Swim"]
        newer.revision += 1
        model.topicChanged(newer)
        #expect(model.appearance.tags == ["Swim"])
        #expect(!model.detailsDirty)
    }

    /// Codex I3-EDIT #2: the stored spelling is what the filter matches, so a canonically equal
    /// but differently spelled tag is a change.
    @Test func aRespelledTagIsAChange() async {
        let model = themed(saved: TopicAppearance(tags: ["caf\u{E9}"]))
        model.appearance.tags = ["cafe\u{301}"]
        #expect(model.detailsDirty, "Save enables and leaving asks (Codex round 2)")
        await model.saveDetails()
        #expect(
            writer.calls == [
                .details(TopicDetailsChange(appearance: AppearanceUpdate(tags: ["cafe\u{301}"])), expectedRevision: 3)
            ])
    }

    @Test func aTagTypedButNotAddedIsSaved() async {
        let model = themed()
        model.appearance.newTag = "swim"
        #expect(model.detailsDirty)
        await model.saveDetails()
        #expect(
            writer.calls == [
                .details(
                    TopicDetailsChange(appearance: AppearanceUpdate(tags: ["Gym", "run", "swim"])), expectedRevision: 3)
            ])
        #expect(model.appearance.newTag.isEmpty)
        #expect(model.appearance.tags == ["Gym", "run", "swim"])
    }

    /// Codex phase 2 #2: a sync that only respells a tag reopens the editor from the new spelling.
    @Test func aRespelledTagFromASyncResetsTheEditor() {
        let model = themed(saved: TopicAppearance(tags: ["caf\u{E9}"]))
        var newer = model.topic
        newer.appearance.tags = ["cafe\u{301}"]
        model.topicChanged(newer)
        #expect(Array(model.appearance.tags[0].unicodeScalars) == Array("cafe\u{301}".unicodeScalars))
        #expect(!model.detailsDirty)
    }

    // MARK: Rebasing on this device's own saves (orchestrator ruling: only a change made elsewhere
    // answers 409)

    @Test func aScheduleSaveThenADetailsAndAppearanceSaveIsNoConflict() async {
        let model = themed()
        model.schedule.kind = .daily
        model.name = "Feelings"
        model.appearance.color = .pink
        await model.saveSchedule()
        #expect(model.topic.revision == 4)
        // The schedule save kept the unsaved details and appearance edits.
        #expect(model.name == "Feelings" && model.appearance.color == .pink)
        await model.saveDetails()
        let change = TopicDetailsChange(name: "Feelings", appearance: AppearanceUpdate(color: .some(.pink)))
        #expect(writer.calls.last == .details(change, expectedRevision: 4))
        #expect(model.detailsBanner == nil)
        #expect(titles == ["Schedule saved", "Saved"])
        #expect(model.topic.revision == 5)
    }

    @Test func detailsThenAppearanceSavesAreNoConflict() async {
        let model = themed()
        model.name = "Feelings"
        await model.saveDetails()
        model.appearance.icon = "☺"
        await model.saveDetails()
        #expect(
            writer.calls.last
                == .details(
                    TopicDetailsChange(appearance: AppearanceUpdate(icon: .some(.emoji("☺\u{FE0F}")))),
                    expectedRevision: 4))
        #expect(model.detailsBanner == nil)
        #expect(titles == ["Saved", "Saved"])
    }

    /// An archive is queued: the store's copy after it is sent brings the new revision, and the
    /// edits in progress stay.
    @Test func anArchiveThenAnAppearanceSaveRebasesOnTheStoresCopy() async {
        let model = themed()
        model.appearance.color = .pink
        await model.archive()
        var archived = model.topic
        archived.status = .archived
        archived.revision = 4
        writer.server = archived
        model.topicChanged(archived)
        #expect(model.appearance.color == .pink, "unsaved edit kept")
        await model.saveDetails()
        #expect(
            writer.calls.last
                == .details(TopicDetailsChange(appearance: AppearanceUpdate(color: .some(.pink))), expectedRevision: 4))
        #expect(model.detailsBanner == nil)
    }

    /// An older copy arriving after this device's own save doesn't put the old revision back.
    @Test func anOlderCopyAfterAnOwnSaveIsIgnored() async {
        let model = themed()
        let before = model.topic
        model.name = "Feelings"
        await model.saveDetails()
        model.topicChanged(before)
        #expect(model.topic.revision == 4 && model.topic.name == "Feelings")
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(model.detailsBanner == nil)
        #expect(
            writer.calls.last
                == .details(TopicDetailsChange(appearance: AppearanceUpdate(color: .some(.pink))), expectedRevision: 4))
    }

    /// A change made elsewhere (another device) that this screen hasn't seen still answers 409.
    @Test func aChangeFromElsewhereStillConflicts() async {
        let model = themed()
        writer.server.revision = 4  // another device saved; no sync yet
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(model.detailsBanner == TopicWriteMessage.staleRevision)
        #expect(model.appearance.color == .pink, "the edit stays to retry")
    }

    /// Codex final #1: a newer copy that the store brought while the save was in flight wins over
    /// the save's (older) answer, so the next save sends the newest revision.
    @Test func aNewerCopyDuringASaveWinsOverItsAnswer() async {
        let model = themed()
        model.name = "Feelings"
        var newer = model.topic
        newer.name = "Feelings"
        newer.appearance.tags = ["Gym", "run", "swim"]
        newer.revision = 5
        writer.whileSaving = { [model] in
            model.topicChanged(newer)
        }
        await model.saveDetails()
        writer.whileSaving = nil
        #expect(model.topic.revision == 5)
        #expect(model.appearance.tags == ["Gym", "run", "swim"])
        writer.server = model.topic
        model.appearance.color = .pink
        await model.saveDetails()
        #expect(
            writer.calls.last
                == .details(TopicDetailsChange(appearance: AppearanceUpdate(color: .some(.pink))), expectedRevision: 5))
        #expect(model.detailsBanner == nil)
    }
}
