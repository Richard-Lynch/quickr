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

    static func shown(_ questions: [Question], last: AnswerValue?, name: String = "Topic") -> WidgetTopic {
        let topic = Topic(
            id: UUID(), slug: name.lowercased(), name: name, description: "", status: .active, currentVersion: 1,
            revision: 1, questionCount: questions.count, entryCount: last == nil ? 0 : 1, lastCapturedAt: nil,
            createdAt: Date(), updatedAt: Date(), archivedAt: nil, schedule: nil, scheduleUpdatedAt: nil,
            questions: questions)
        return WidgetTopic(topic: topic, quick: QuickLog(questions: questions), lastAnswer: last)
    }

    // MARK: - Control

    @Test func aChipTopicsControlLogsItsLastOptionAgain() {
        let value = TopicControlValue(Self.shown([Self.mood], last: .string("meh"), name: "Mood"))
        #expect(value.logs && value.detail == "Meh" && value.title == "Mood")
        #expect(value.intent.option?.id == value.option?.id && value.intent.number == nil)
    }

    @Test func aChipTopicNeverLoggedDoesntGuess() {
        let value = TopicControlValue(Self.shown([Self.mood], last: nil))
        #expect(!value.logs && value.detail == "Log it in quickR first")
        #expect(value.intent.option == nil && value.intent.number == nil, "INTENTS declines: no value")
    }

    @Test func aNumberTopicsControlLogsTheLastValueOrTheStart() {
        let last = TopicControlValue(Self.shown([Self.cups], last: .int(3)))
        #expect(last.logs && last.intent.number == 3 && last.detail == "3 cups")
        let start = TopicControlValue(Self.shown([Self.cups], last: nil))
        #expect(start.intent.number == 0, "the stepper's start (min), like the tile's ✓")
    }

    @Test func aTopicThatNeedsTheFormHasNoOnePressLog() {
        let value = TopicControlValue(Self.shown([Self.place, Self.notes, Self.cups], last: nil))
        #expect(!value.logs && value.detail == "Needs the form: log it in quickR")
    }

    // MARK: - Widget buttons

    @Test func aWidgetsChipsAndCheckRunFullySpecifiedLogs() throws {
        let mood = Self.shown([Self.mood], last: .string("good"), name: "Mood")
        let actions = TopicWidgetEntryView.actions(mood)
        let option = try #require(actions.option(EnumOption(value: "meh", label: "Meh")) as? LogEntryIntent)
        #expect(option.topic.id == mood.id && option.option?.id.hasSuffix("meh") == true)

        let water = Self.shown([Self.cups], last: .int(3), name: "Water")
        let check = try #require(TopicWidgetEntryView.actions(water).number(.int(3)) as? LogEntryIntent)
        #expect(check.topic.id == water.id && check.number == 3 && check.option == nil)
        #expect(TopicWidgetEntryView.actions(water).option(EnumOption(value: "x", label: "X")) == nil)
    }
}
