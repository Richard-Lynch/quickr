import Foundation
import QuickrCore
import QuickrData
import QuickrUI
import Testing

@testable import QuickR

/// The widget extension's intents: what a topic widget's chip or ✓ runs, and what a topic's Control
/// does (one fully specified `LogEntryIntent`, never a prompt).
@Suite @MainActor struct WidgetControlTests {
    static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "meh", label: "Meh")])))
    static let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 10, unit: "cups")))
    static let notes = Question(key: "notes", label: "Notes", kind: .string(.init()))
    static let place = Question(
        key: "place", label: "Place",
        kind: .choice(.init(options: [.init(value: "home", label: "Home")])))

    static let scope = EntryScope("server-a/1")

    static func shown(
        _ questions: [Question], last: AnswerValue?, name: String = "Topic", scope: EntryScope? = Self.scope
    ) -> WidgetTopic {
        let topic = Topic(
            id: UUID(), slug: name.lowercased(), name: name, description: "", status: .active, currentVersion: 1,
            revision: 1, questionCount: questions.count, entryCount: last == nil ? 0 : 1, lastCapturedAt: nil,
            createdAt: Date(), updatedAt: Date(), archivedAt: nil, schedule: nil, scheduleUpdatedAt: nil,
            questions: questions)
        return WidgetTopic(topic: topic, quick: QuickLog(questions: questions), lastAnswer: last, scope: scope)
    }

    // MARK: - Control

    @Test func aChipTopicsControlLogsItsLastOptionAgainInItsStore() {
        let value = TopicControlValue(Self.shown([Self.mood], last: .string("meh"), name: "Mood"))
        #expect(value.logs && value.detail == "Meh" && value.title == "Mood")
        #expect(value.intent.option?.value == "meh" && value.intent.number == nil)
        #expect(value.intent.scope == Self.scope.id)
    }

    /// Nothing to repeat: the action carries no value, so it says so instead of prompting
    /// (WidgetLogTests runs it).
    @Test func aChipTopicNeverLoggedDoesntGuess() {
        let value = TopicControlValue(Self.shown([Self.mood], last: nil))
        #expect(!value.logs && value.detail == "Log it in quickR first")
        #expect(value.intent.option == nil && value.intent.number == nil && value.intent.topic != nil)
    }

    /// The label shows what it logs: the last value, or the start once the rules changed (20 cups
    /// isn't allowed any more: 0 cups, not "20 cups" while logging 0).
    @Test func aNumberTopicsControlShowsWhatItLogs() {
        let last = TopicControlValue(Self.shown([Self.cups], last: .int(3)))
        #expect(last.logs && last.intent.number == 3 && last.detail == "3 cups")
        let changed = TopicControlValue(Self.shown([Self.cups], last: .int(20)))
        #expect(changed.intent.number == 0 && changed.detail == "0 cups")
        let never = TopicControlValue(Self.shown([Self.cups], last: nil))
        #expect(never.intent.number == 0 && never.detail == "0 cups", "the stepper's start, like the tile's ✓")
    }

    /// SINGLE: a topic with no questions always logs in one press (an entry with no answers), from
    /// its Control and its widget's "Log it" chip, pinned to the widget's store.
    @Test func aSingleTopicLogsFromItsControlAndItsWidget() throws {
        let shown = Self.shown([], last: nil, name: "Walk")
        let value = TopicControlValue(shown)
        #expect(value.logs && value.detail == "Log it" && value.title == "Walk")
        #expect(value.intent.option == nil && value.intent.number == nil && value.intent.topic != nil)
        #expect(value.intent.scope == Self.scope.id)
        let chip = try #require(TopicWidgetEntryView.actions(shown).single() as? WidgetLogIntent)
        #expect(chip.option == nil && chip.number == nil && chip.scope == Self.scope.id)
        #expect(TopicWidgetEntryView.actions(Self.shown([Self.mood], last: nil)).single() == nil, "not single")
    }

    @Test func aTopicThatNeedsTheFormHasNoOnePressLog() {
        let value = TopicControlValue(Self.shown([Self.place, Self.notes, Self.cups], last: nil))
        #expect(!value.logs && value.detail == "Needs the form: log it in quickR")
    }

    @Test func withoutAStoreTheControlIsUnconfigured() {
        let value = TopicControlValue(Self.shown([Self.mood], last: .string("meh"), scope: nil))
        #expect(!value.logs && value.title == "Choose a topic" && value.intent.topic == nil)
    }

    // MARK: - Widget buttons

    @Test func aWidgetsChipsAndCheckRunPinnedLogs() throws {
        let mood = Self.shown([Self.mood], last: .string("good"), name: "Mood")
        let actions = TopicWidgetEntryView.actions(mood)
        let option = try #require(actions.option(EnumOption(value: "meh", label: "Meh")) as? WidgetLogIntent)
        #expect(option.topic?.id == mood.id && option.option?.value == "meh" && option.scope == Self.scope.id)

        let water = Self.shown([Self.cups], last: .int(3), name: "Water")
        let check = try #require(TopicWidgetEntryView.actions(water).number(.int(3)) as? WidgetLogIntent)
        #expect(check.topic?.id == water.id && check.number == 3 && check.option == nil)
        #expect(TopicWidgetEntryView.actions(water).option(EnumOption(value: "x", label: "X")) == nil)

        let sample = Self.shown([Self.mood], last: nil, scope: nil)
        #expect(
            TopicWidgetEntryView.actions(sample).option(EnumOption(value: "meh", label: "Meh")) == nil,
            "no store: the record screen opens instead")
    }
}
