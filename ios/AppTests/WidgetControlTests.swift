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

    // MARK: - Timed topics (timers.md §11.3, active-surfaces.md §5.2)

    /// A timed topic, with the run its widget shows: a step open (`stepIndex` 0, `next` the step
    /// after it, nil on the last step), or a lap (`stepIndex` nil, "Lap 2").
    static func timed(status: String? = nil, next: String? = "Breakfast", stepIndex: Int? = 0) -> WidgetTopic {
        var shown = Self.shown([], last: nil, name: "Morning")
        shown.topic.timer = TopicTimer(steps: stepIndex == nil ? [] : [TopicTimer.Step(key: "shower", label: "Shower")])
        if let status {
            shown.run = RunActivityState(
                runId: "00000000-0000-4000-8000-0000000000aa", revision: 1, status: status, startedAt: 0, seg: 2,
                segStartedAt: 0, label: stepIndex == nil ? "Lap 2" : "Shower", stepIndex: stepIndex,
                stepCount: stepIndex == nil ? 0 : 2, nextLabel: next, pausedAt: status == "paused" ? 10 : nil,
                pausedMsBeforeSeg: 0, pausedMsInSeg: 0, endedAt: nil, activeMs: nil)
            shown.hasOpenRun = status == "running" || status == "paused"
        }
        return shown
    }

    @Test func aTimedTopicsLogControlNeverLogsItUntimed() {
        let value = TopicControlValue(Self.timed())
        #expect(!value.logs)
        #expect(value.detail == "Timed: use the Timer control")
    }

    /// The detail says what the one press does (§5.2, §1.3): Start; "Next: Breakfast" while a step
    /// follows; Stop on the last step and on a lap, the §5.3 carve-out of a timer without lap
    /// types. A lap-typed timer's branch is `theTimerControlOfALapTypedTimerLaps`.
    @Test func theTimerControlRunsAutoAndSaysWhatAPressDoes() {
        let idle = TimerControlValue(Self.timed())
        #expect(idle.title == "Timer: Morning")
        #expect(idle.detail == "Start")
        #expect(idle.icon == "play")
        let idleAction: String? = idle.intent.action
        #expect(idleAction == "auto")
        let idleScope: String? = idle.intent.scope
        #expect(idleScope == Self.scope.id)
        let idleRun: String? = idle.intent.runId
        #expect(idleRun == nil, "Auto acts on the current state")

        let running = TimerControlValue(Self.timed(status: "running"))
        #expect(running.detail == "Next: Breakfast")
        #expect(running.icon == "chevron.right")
        let paused = TimerControlValue(Self.timed(status: "paused"))
        #expect(paused.detail == "Next: Breakfast", "the primary doesn't change while paused")
        let last = TimerControlValue(Self.timed(status: "running", next: nil))
        #expect(last.detail == "Stop")
        #expect(last.icon == "stop")
        let lap = TimerControlValue(Self.timed(status: "running", next: nil, stepIndex: nil))
        #expect(lap.detail == "Stop", "§5.3: a stopwatch without lap types still stops in one press")
        #expect(lap.icon == "stop")
        let lapAction: String? = lap.intent.action
        #expect(lapAction == "auto", "one Control, one intent: Auto decides")
        let finishing = TimerControlValue(Self.timed(status: "finishing", next: nil))
        #expect(finishing.detail == "Start", "a finishing run isn't open: a press starts a new one")

        let untimed = TimerControlValue(Self.shown([Self.mood], last: nil))
        let untimedAction: String? = untimed.intent.action
        #expect(untimedAction == nil, "an empty intent: a press does nothing")
        #expect(untimed.detail == "Not timed")
        let noStore = TimerControlValue(Self.shown([Self.mood], last: nil, scope: nil))
        #expect(noStore.title == "Choose a topic")
    }

    /// §5.2, §5.3 on a lap-typed timer (#222): Auto is the on-screen primary, so on a lap the one
    /// press laps and the detail names the lap it opens ("Lap → Rest", icon flag), never Stop. The
    /// open run's pinned timer decides, as `RunWrites.auto` presses it (the topic's current timer
    /// without lap types here: an edit after the start changes nothing).
    @Test func theTimerControlOfALapTypedTimerLaps() {
        var typed = Self.timed(status: "running", next: "Rest", stepIndex: nil)
        typed.runLapTyped = true
        #expect(typed.isLapTyped)
        let lap = TimerControlValue(typed)
        #expect(lap.detail == "Lap → Rest")
        #expect(lap.icon == "flag")
        let action: String? = lap.intent.action
        #expect(action == "auto")
        typed.run?.nextLabel = nil
        #expect(TimerControlValue(typed).detail == "Lap", "a lap type without a next label: plain Lap")

        // The same run on a timer without lap types: v1's Auto stops it (the carve-out).
        typed.runLapTyped = false
        #expect(TimerControlValue(typed).detail == "Stop")
        #expect(TimerControlValue(typed).icon == "stop")
    }

    /// M2-REVIEW: a lap opened mid-steps on a timer without lap types. Its activity state names no
    /// next step (a lap never does), but the press is Next (`RunWrites.autoTap`, carried as
    /// `runAuto` by the reader), so the Control says "Next" with the chevron, not "Stop".
    @Test func theTimerControlOfALapBeforeAPendingStepSaysNext() {
        var lap = Self.timed(status: "running", next: nil, stepIndex: nil)
        #expect(TimerControlValue(lap).detail == "Stop", "the activity state alone reads the carve-out")
        lap.runAuto = .next
        let value = TimerControlValue(lap)
        #expect(value.detail == "Next")
        #expect(value.icon == "chevron.right")
        let action: String? = value.intent.action
        #expect(action == "auto")
    }

    @Test func aTimedWidgetsButtonsCarryTheRunAndSegmentShown() throws {
        let running = Self.timed(status: "running")
        let actions = TopicWidgetEntryView.actions(running)
        let next = try #require(actions.run(.next) as? RunWidgetIntent)
        let action: String? = next.action
        #expect(action == "next")
        let topicId: String? = next.topicId
        #expect(topicId == running.id.wireString)
        let scope: String? = next.scope
        #expect(scope == Self.scope.id)
        let runId: String = try #require(next.runId)
        #expect(runId == "00000000-0000-4000-8000-0000000000aa")
        let seg: Int = try #require(next.seg)
        #expect(seg == 2)
        let start = try #require(TopicWidgetEntryView.actions(Self.timed()).run(.start) as? RunWidgetIntent)
        let startAction: String? = start.action
        #expect(startAction == "start")
        let startRun: String? = start.runId
        #expect(startRun == nil)

        var sample = Self.timed(status: "running")
        sample.scope = nil
        #expect(TopicWidgetEntryView.actions(sample).run(.next) == nil, "no store: the run screen opens instead")
    }
}
