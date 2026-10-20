import Foundation
import QuickrCore
import QuickrUI
import Synchronization
import Testing

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private let workout = Topic(
    id: UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c10")!, slug: "workout", name: "Workout",
    currentVersion: 2, revision: 1, questionCount: 2, createdAt: start, updatedAt: start,
    questions: [
        Question(
            key: "type", label: "Type",
            kind: .choice(
                .init(options: [EnumOption(value: "run", label: "Run"), EnumOption(value: "yoga", label: "Yoga")]))),
        Question(key: "duration", label: "Duration", kind: .int(.init(min: 1, max: 600, unit: "min"))),
    ])

private let mood = Topic(
    id: UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c11")!, slug: "mood", name: "Mood",
    currentVersion: 1, revision: 1, questionCount: 1, createdAt: start, updatedAt: start,
    questions: [
        Question(
            key: "mood", label: "Mood",
            kind: .choice(
                .init(options: [EnumOption(value: "good", label: "Good"), EnumOption(value: "bad", label: "Bad")])))
    ])

/// A clock the test moves.
final class RecordClock: Sendable {
    private let value = Mutex(start)
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
final class RecordFakeWriter: RecordWriter {
    var delivery: RecordDelivery = .sent
    var logError: (any Error)?
    private(set) var logged: [(answers: [String: AnswerValue], capturedAt: Date, notes: String?)] = []
    private(set) var fixes: [(itemId: String, answers: [String: AnswerValue], capturedAt: Date, notes: String?)] = []
    private(set) var discarded: [UUID] = []
    private(set) var sent: [UUID] = []

    func log(_ topic: Topic, answers: [String: AnswerValue], capturedAt: Date, notes: String?) async throws -> UUID {
        if let logError { throw logError }
        logged.append((answers, capturedAt, notes))
        return UUID()
    }

    func sendNow(_ entryId: UUID) async -> RecordDelivery {
        sent.append(entryId)
        return delivery
    }

    func discard(_ entryId: UUID) async { discarded.append(entryId) }

    func fix(
        _ fix: RecordFix, topic: Topic, answers: [String: AnswerValue], capturedAt: Date, notes: String?
    ) async throws {
        fixes.append((fix.itemId, answers, capturedAt, notes))
    }

    func failure(_ error: any Error) -> RecordFailure { .message("\(error)") }
}

@MainActor
final class RecordFakeNotices: RecordNotices {
    enum Event: Equatable {
        case logged(sent: Bool)
        case fixed(sent: Bool)
        case failed(RecordFailure)
    }

    private(set) var events: [Event] = []

    func logged(entryId: UUID, topic: Topic, sent: Bool) { events.append(.logged(sent: sent)) }
    func fixed(topic: Topic, sent: Bool) { events.append(.fixed(sent: sent)) }
    func failed(topic: Topic, _ failure: RecordFailure) { events.append(.failed(failure)) }
}

struct RecordBoom: Error {}

@MainActor @Suite struct RecordModelTests {
    let clock = RecordClock()
    let writer = RecordFakeWriter()
    let notices = RecordFakeNotices()

    func model(_ topic: Topic = workout, _ mode: RecordModel.Mode = .new(last: nil), another: Bool = false)
        -> RecordModel
    {
        let clock = clock
        return RecordModel(
            topic: topic, mode: mode, writer: writer, notices: notices, logAnother: another, now: { clock.now })
    }

    func fill(_ model: RecordModel, type: String = "run", duration: String = "30") {
        model.form.change("type", to: .text(type))
        model.form.change("duration", to: .text(duration))
    }

    // MARK: New entries

    @Test func aSentEntryToastsWithUndoAndCloses() async {
        let model = model()
        #expect(!model.hasUnsavedChanges)
        fill(model)
        #expect(model.hasUnsavedChanges)
        clock.advance(90)
        #expect(await model.save() == .leave)
        #expect(writer.logged.count == 1)
        #expect(writer.logged.first?.answers == ["type": .string("run"), "duration": .int(30)])
        // Untouched, "captured at" is the moment of Save, not of opening.
        #expect(writer.logged.first?.capturedAt == start.addingTimeInterval(90))
        #expect(writer.logged.first?.notes == nil)
        #expect(notices.events == [.logged(sent: true)])
        #expect(!model.hasUnsavedChanges && !model.isSaving)
    }

    @Test func aQueuedEntrySaysItWillSync() async {
        writer.delivery = .queued
        let model = model()
        fill(model)
        #expect(await model.save() == .leave)
        #expect(notices.events == [.logged(sent: false)])
    }

    @Test func anInvalidFormWritesNothing() async {
        let model = model()
        model.form.change("type", to: .text("run"))
        #expect(await model.save() == .stay)
        #expect(writer.logged.isEmpty && notices.events.isEmpty)
        #expect(model.form.errors["duration"] == "Required")
    }

    @Test func aRejectedEntryGoesBackOnTheFormAndLeavesTheQueue() async throws {
        writer.delivery = .rejected(
            Problem(
                code: .invalidAnswers, detail: "Some answers need attention",
                errors: [
                    FieldIssue(location: [.key("answers"), .key("duration")], message: "Must be at most 120 min"),
                    FieldIssue(location: [.key("notes")], message: "Too long"),
                ]), message: "422")
        let model = model()
        fill(model)
        #expect(await model.save() == .stay)
        #expect(writer.discarded.count == 1 && writer.discarded == writer.sent)
        #expect(model.form.errors["duration"] == "Must be at most 120 min")
        #expect(model.form.banner?.message == "Some answers need attention")
        #expect(model.metaErrors == [.notes: "Too long"])
        #expect(model.showsDetails)
        #expect(notices.events.isEmpty)
        #expect(model.hasUnsavedChanges, "still the user's answers")
    }

    @Test func notesAndATimeTravelWithTheEntry() async {
        let model = model()
        fill(model)
        model.notes = "  easy pace \n"
        model.capturedAt = start.addingTimeInterval(-3600)
        clock.advance(60)
        #expect(await model.save() == .leave)
        #expect(writer.logged.first?.notes == "easy pace")
        #expect(writer.logged.first?.capturedAt == start.addingTimeInterval(-3600))
    }

    @Test func detailsAreCheckedBeforeAnyWrite() async {
        let model = model()
        fill(model)
        model.capturedAt = start.addingTimeInterval(48 * 3600)
        #expect(await model.save() == .stay)
        #expect(model.metaErrors[.capturedAt] == "Can’t be more than 24 hours in the future")
        #expect(model.showsDetails)
        model.capturedAt = start
        model.notes = String(repeating: "n", count: Limits.serverDefaults.maxNotesLength + 1)
        #expect(await model.save() == .stay)
        #expect(model.metaErrors[.notes] == "At most 5000 characters")
        #expect(writer.logged.isEmpty)
        model.notes = "ok"
        #expect(await model.save() == .leave)
        #expect(model.metaErrors.isEmpty)
    }

    @Test func logAnotherStaysWithAFreshFormOfferingWhatWasJustLogged() async throws {
        let model = model(another: true)
        fill(model, duration: "45")
        model.notes = "first"
        #expect(await model.save() == .stay)
        #expect(model.loggedCount == 1)
        #expect(notices.events == [.logged(sent: true)])
        #expect(model.form.input(for: "duration") == .text(""))
        #expect(model.notes.isEmpty && !model.hasUnsavedChanges)
        let prefill = try #require(model.form.prefill)
        #expect(prefill.inputs["duration"] == .text("45"))
        #expect(model.form.showsSameAsLast)

        model.form.toggleSameAsLast()
        #expect(await model.save() == .stay)
        #expect(model.loggedCount == 2)
        #expect(
            writer.logged.map(\.answers) == [
                ["type": .string("run"), "duration": .int(45)], ["type": .string("run"), "duration": .int(45)],
            ])
        model.logAnother = false
        fill(model)
        #expect(await model.save() == .leave)
    }

    @Test func aFailedWriteSaysSoAndStays() async {
        writer.logError = RecordBoom()
        let model = model()
        fill(model)
        #expect(await model.save() == .stay)
        #expect(notices.events == [.failed(.message("RecordBoom()"))])
        #expect(model.hasUnsavedChanges)
    }

    @Test func anEntryDeletedMeanwhileIsNotSaved() async {
        writer.delivery = .notSaved
        let model = model()
        fill(model)
        #expect(await model.save() == .leave)
        #expect(notices.events == [.failed(.notSaved)])
    }

    @Test func aSingleChipTopicSavesOnPick() async throws {
        let model = model(mood)
        #expect(model.form.autoSaveKey == "mood")
        let body = try #require(model.form.change("mood", to: .text("good")))
        #expect(await model.autoSave(body))
        #expect(writer.logged.first?.answers == ["mood": .string("good")])
        #expect(notices.events == [.logged(sent: true)])

        writer.delivery = .rejected(nil, message: "Server error")
        let again = self.model(mood)
        let second = try #require(again.form.change("mood", to: .text("bad")))
        #expect(await again.autoSave(second) == false)
    }

    // MARK: Fix mode

    func fix(problem: Problem?) -> RecordFix {
        RecordFix(
            itemId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301", rowVersion: 3,
            answers: ["type": .string("run"), "duration": .int(900)], capturedAt: start.addingTimeInterval(-7200),
            notes: "long one", problem: problem, message: "Rejected (422)")
    }

    let rejected = Problem(
        code: .invalidAnswers, detail: "Some answers need attention",
        errors: [
            FieldIssue(location: [.key("answers"), .key("duration")], message: "Must be at most 600 min"),
            FieldIssue(location: [.key("captured_at")], message: "Too old"),
        ])

    @Test func fixModeShowsWhatWasSentAndWhyItWasRefused() {
        let model = model(workout, .fix(fix(problem: rejected)))
        #expect(model.isFixing)
        #expect(model.form.input(for: "duration") == .text("900"))
        #expect(model.form.errors["duration"] == "Must be at most 600 min")
        #expect(model.metaErrors == [.capturedAt: "Too old"])
        #expect(model.showsDetails)
        #expect(model.capturedAt == start.addingTimeInterval(-7200))
        #expect(model.notes == "long one")
        #expect(model.fixMessage == nil)
        #expect(!model.hasUnsavedChanges)

        let noProblem = self.model(workout, .fix(fix(problem: nil)))
        #expect(noProblem.fixMessage == "Rejected (422)")
    }

    @Test func savingAFixReplacesTheItemAndCloses() async {
        let model = model(workout, .fix(fix(problem: rejected)))
        model.form.change("duration", to: .text("90"))
        clock.advance(600)
        #expect(await model.save() == .leave)
        #expect(writer.fixes.count == 1)
        #expect(writer.fixes.first?.itemId == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(writer.fixes.first?.answers == ["type": .string("run"), "duration": .int(90)])
        // A fix keeps the time it was captured, not the moment of the fix.
        #expect(writer.fixes.first?.capturedAt == start.addingTimeInterval(-7200))
        #expect(writer.logged.isEmpty)
        #expect(notices.events == [.fixed(sent: true)])
    }

    @Test func aFixRejectedAgainStaysAndKeepsTheItem() async {
        writer.delivery = .rejected(rejected, message: "422")
        let model = model(workout, .fix(fix(problem: rejected)))
        model.form.change("duration", to: .text("700"))
        #expect(await model.save() == .stay)
        #expect(writer.discarded.isEmpty, "a fix is only discarded from the sync sheet")
        #expect(model.form.errors["duration"] == "Must be at most 600 min")
        #expect(notices.events.isEmpty)
    }

    // MARK: Guard

    @Test func theGuardFollowsAnyChange() async {
        let model = model()
        #expect(!model.hasUnsavedChanges)
        model.notes = "x"
        #expect(model.hasUnsavedChanges)
        model.notes = ""
        #expect(!model.hasUnsavedChanges)
        model.capturedAt = start.addingTimeInterval(-60)
        #expect(model.hasUnsavedChanges)

        let other = self.model()
        other.form.change("duration", to: .text("5"))
        #expect(other.hasUnsavedChanges)
        other.form.change("duration", to: .text(""))
        #expect(!other.hasUnsavedChanges)
    }
}
