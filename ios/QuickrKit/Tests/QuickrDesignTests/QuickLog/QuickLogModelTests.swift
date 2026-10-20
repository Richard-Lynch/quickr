import Foundation
import QuickrCore
import QuickrUI
import Testing

/// A writer whose answers the test sets; `log` can be held open to see the busy state.
@MainActor final class FakeEntryWriter: EntryWriter {
    struct Logged: Equatable {
        var topic: UUID
        var answers: [String: AnswerValue]
    }

    var logged: [Logged] = []
    var sendWaits: [Duration] = []
    var undoneLogs: [UUID] = []
    var undoneDeletes: [UUID] = []
    var logError: (any Error)?
    var delivery: EntryDelivery = .sent
    var undoError: (any Error)?
    var restores = true
    /// While set, `log` waits for `release()`.
    var holdLog = false
    private var held: [CheckedContinuation<Void, Never>] = []
    let ids = (0..<8).map { _ in UUID() }

    func log(_ topic: QuickLogTopic, answers: [String: AnswerValue]) async throws -> UUID {
        if holdLog { await withCheckedContinuation { held.append($0) } }
        if let logError { throw logError }
        logged.append(Logged(topic: topic.id, answers: answers))
        return ids[logged.count - 1]
    }

    func release() {
        holdLog = false
        let waiting = held
        held = []
        for c in waiting { c.resume() }
    }

    var isHolding: Bool { !held.isEmpty }

    func sendNow(_ entryId: UUID, wait: Duration) async -> EntryDelivery {
        sendWaits.append(wait)
        return delivery
    }

    func undoLog(_ entryId: UUID) async throws {
        if let undoError { throw undoError }
        undoneLogs.append(entryId)
    }

    func undoDelete(_ entryId: UUID) async throws -> Bool {
        if let undoError { throw undoError }
        undoneDeletes.append(entryId)
        return restores
    }

    func failure(_ error: any Error) -> EntryWriteFailure {
        if let error = error as? FakeError, error == .deleted { return .notSaved }
        return .message("\(error)")
    }
}

enum FakeError: Error, CustomStringConvertible {
    case deleted
    case offline

    var description: String { self == .deleted ? "deleted" : "The store was reset" }
}

@MainActor struct QuickLogWorld {
    let writer = FakeEntryWriter()
    let center: ToastCenter
    let toasts: EntryToasts
    let drafts = QuickLogDrafts()
    let sleeper = Sleeper()

    init() {
        let sleeper = sleeper
        center = ToastCenter(sleep: { try await sleeper.sleep($0) })
        toasts = EntryToasts(center: center, writer: writer)
    }

    func model(_ topic: QuickLogTopic, last: AnswerValue? = nil) -> QuickLogModel {
        let sleeper = sleeper
        return QuickLogModel(
            topic: topic, last: last, writer: writer, toasts: toasts, drafts: drafts,
            flash: ConfirmFlash(sleep: { try await sleeper.sleep($0) }))
    }

    var toastTitles: [String] { center.items.map(\.toast.title) }
    var lastToast: Toast? { center.items.last?.toast }
}

enum Topics {
    static let severity = [
        EnumOption(value: "none", label: "None"), EnumOption(value: "mild", label: "Mild"),
        EnumOption(value: "severe", label: "Severe"),
    ]
    static let headacheQuestion = Question(
        key: "severity", label: "Severity", required: true,
        kind: .choice(.init(options: severity, multiple: false)))
    static let headache = QuickLogTopic(
        id: UUID(), slug: "headache", name: "Headache", version: 3,
        quick: QuickLog(questions: [headacheQuestion])!)

    static func water(unit: String? = "glasses", min: Int? = 0) -> QuickLogTopic {
        let question = Question(
            key: "glasses", label: "Glasses", required: true, kind: .int(.init(min: min, max: 20, unit: unit)))
        return QuickLogTopic(
            id: UUID(), slug: "water", name: "Water", version: 1, quick: QuickLog(questions: [question])!)
    }
}

@MainActor @Suite(.timeLimit(.minutes(2))) struct QuickLogChipTests {
    @Test func aChipLogsItsOptionWaitsForTheServerThenLightsWithAnUndoToast() async throws {
        let w = QuickLogWorld()
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[1])
        #expect(w.writer.logged == [.init(topic: Topics.headache.id, answers: ["severity": .string("mild")])])
        #expect(w.writer.sendWaits == [.milliseconds(2500)])
        #expect(model.flash.value == "mild" && model.busyOption == nil)
        let toast = try #require(w.lastToast)
        #expect(toast.title == "Logged Mild" && toast.message == "Headache" && toast.tone == .ok)
        #expect(toast.action?.label == "Undo" && toast.duration == .seconds(6))
    }

    @Test func aQueuedLogSaysItWillSync() async throws {
        let w = QuickLogWorld()
        w.writer.delivery = .queued
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[0])
        let toast = try #require(w.lastToast)
        #expect(toast.title == "Logged None" && toast.tone == .info)
        #expect(toast.message == "Headache · saved on this device, will sync")
        #expect(model.flash.value == "none")
    }

    @Test func everyChipIsBusyUntilTheOutcomeAndASecondTapIsIgnored() async {
        let w = QuickLogWorld()
        w.writer.holdLog = true
        let model = w.model(Topics.headache)
        let first = Task { await model.pick(Topics.severity[1]) }
        await waitUntil { w.writer.isHolding }
        #expect(model.busyOption == "mild")
        let second = Task { await model.pick(Topics.severity[2]) }  // ignored
        w.writer.release()
        await first.value
        await second.value
        #expect(w.writer.logged.count == 1 && model.busyOption == nil)
        #expect(model.flash.value == "mild")
    }

    @Test func aRefusedLogDoesntLightAndSaysWhy() async throws {
        let w = QuickLogWorld()
        w.writer.delivery = .failed("Mood is required")
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[1])
        #expect(model.flash.value == nil)
        let toast = try #require(w.lastToast)
        #expect(toast.title == "Couldn’t log Headache" && toast.message == "Mood is required")
        #expect(toast.tone == .danger && toast.action == nil)
    }

    @Test func aDeletedEntryIsNotSaved() async throws {
        let w = QuickLogWorld()
        w.writer.delivery = .notSaved
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[1])
        #expect(w.toastTitles == ["Not saved"] && model.flash.value == nil)

        w.writer.logError = FakeError.deleted
        await model.pick(Topics.severity[1])
        #expect(w.toastTitles == ["Not saved", "Not saved"])
    }

    @Test func aWriteRefusedBeforeQueueingShowsItsMessageAndNeverSends() async throws {
        let w = QuickLogWorld()
        w.writer.logError = FakeError.offline
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[1])
        #expect(w.writer.sendWaits.isEmpty && model.flash.value == nil && model.busyOption == nil)
        #expect(w.lastToast?.message == "The store was reset")
    }

    @Test func theConfirmationLastsOnePointSixSeconds() async {
        let w = QuickLogWorld()
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[1])
        // Two sleeps: the toast's 6 s and the flash's 1.6 s.
        await w.sleeper.waitFor(requested: 2, asleep: 2)
        #expect(await w.sleeper.requested.contains(.milliseconds(1600)))
        await w.sleeper.wakeAll()
        await waitUntil { model.flash.value == nil }
        #expect(model.flash.value == nil)
    }

    @Test func theDotMarksTheLastOption() {
        let w = QuickLogWorld()
        #expect(w.model(Topics.headache, last: .string("severe")).lastOption == "severe")
        #expect(w.model(Topics.headache, last: .int(2)).lastOption == nil)
        #expect(w.model(Topics.headache).lastOption == nil)
    }
}

@MainActor @Suite(.timeLimit(.minutes(2))) struct QuickLogNumberTests {
    @Test func theFieldStartsFromTheLastValueElseTheMinimum() {
        let w = QuickLogWorld()
        #expect(w.model(Topics.water(), last: .int(3)).numberText == "3")
        #expect(w.model(Topics.water()).numberText == "0")
        #expect(w.model(Topics.water(min: nil)).numberText == "")
        #expect(w.model(Topics.water(), last: .int(99)).numberText == "0")  // above max: not offered
    }

    @Test func aDraftSurvivesANewModelAndWinsOverTheLastValue() {
        let w = QuickLogWorld()
        let topic = Topics.water()
        let first = w.model(topic, last: .int(3))
        first.numberText = "7"
        #expect(w.model(topic, last: .int(3)).numberText == "7")
        #expect(w.model(Topics.water(), last: .int(3)).numberText == "3")  // another topic
    }

    @Test func checkLogsTheValueWithItsUnitAndClearsTheDraft() async throws {
        let w = QuickLogWorld()
        let topic = Topics.water()
        let model = w.model(topic, last: .int(3))
        model.numberText = "5"
        await model.logNumber()
        #expect(w.writer.logged == [.init(topic: topic.id, answers: ["glasses": .int(5)])])
        #expect(w.lastToast?.title == "Logged 5 glasses")
        #expect(w.drafts[topic.id] == nil && model.numberText == "3")
        #expect(model.flash.value == nil)  // no chip to light
    }

    @Test func aRefusedLogKeepsTheDraft() async {
        let w = QuickLogWorld()
        w.writer.delivery = .failed("Too many")
        let topic = Topics.water()
        let model = w.model(topic)
        model.numberText = "5"
        await model.logNumber()
        #expect(w.drafts[topic.id] == "5")
        #expect(w.lastToast?.title == "Couldn’t log Water")
    }

    @Test func anInvalidValueShowsItsMessageUntilEdited() async {
        let w = QuickLogWorld()
        let model = w.model(Topics.water())
        model.numberText = "21"
        await model.logNumber()
        #expect(w.writer.logged.isEmpty && model.numberError != nil)
        model.numberText = ""
        #expect(model.numberError == nil)
        await model.logNumber()
        #expect(model.numberError == "Required" && w.writer.logged.isEmpty)
    }

    @Test func theLabelAddsTheUnitOnlyWhenItSaysSomethingNew() {
        let w = QuickLogWorld()
        #expect(w.model(Topics.water()).numberLabel == "Glasses")  // same word
        #expect(w.model(Topics.water(unit: "ml")).numberLabel == "Glasses (ml)")
        #expect(w.model(Topics.water(unit: nil)).numberLabel == "Glasses")
    }
}

@MainActor @Suite(.timeLimit(.minutes(2))) struct EntryToastTests {
    @Test func undoInTheLoggedToastUndoesThatEntry() async throws {
        let w = QuickLogWorld()
        let model = w.model(Topics.headache)
        await model.pick(Topics.severity[1])
        let id = try #require(w.center.items.last?.id)
        w.center.performAction(id)
        await waitUntil { w.toastTitles.last == "Undone" }
        #expect(w.writer.undoneLogs == [w.writer.ids[0]])
        #expect(w.lastToast?.message == "Headache entry removed." && w.lastToast?.tone == .info)
        #expect(!w.toastTitles.contains("Logged Mild"))  // the action dismissed it
    }

    @Test func aFailedUndoSaysWhereToDeleteIt() async {
        let w = QuickLogWorld()
        w.writer.undoError = FakeError.offline
        await w.toasts.undoLog(entryId: UUID(), topicName: "Headache")
        #expect(w.lastToast?.title == "Couldn’t undo")
        #expect(w.lastToast?.message == "The store was reset — delete it from Headache › Entries.")
    }

    @Test func undoOfADeleteRestoresItWhileHeld() async throws {
        let w = QuickLogWorld()
        let entry = UUID()
        w.toasts.deleted(entryId: entry)
        #expect(w.lastToast?.title == "Entry deleted" && w.lastToast?.duration == .seconds(6))
        w.center.performAction(try #require(w.center.items.last?.id))
        await waitUntil { w.toastTitles.last == "Entry restored" }
        #expect(w.writer.undoneDeletes == [entry])
    }

    @Test func undoOfADeleteThatAlreadyLeftSaysSo() async {
        let w = QuickLogWorld()
        w.writer.restores = false
        await w.toasts.undoDelete(entryId: UUID())
        #expect(w.lastToast?.title == "Couldn’t undo" && w.lastToast?.message == "The delete was already sent.")
    }
}
