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

/// The record screen's writer, with the app's scope rules: an entry is tied to the store it went
/// to; `sendNow` for another store's entry is `.queued` (it waits there), and discard, fix, Undo
/// and `rowVersion` throw `scopeChanged` once their store isn't the active one.
@MainActor
final class RecordFakeWriter: EntryFixing {
    var scope: EntryScope? = EntryScope("server-A/1")
    var delivery: EntryDelivery = .sent
    var logError: (any Error)?
    private(set) var logged: [(answers: [String: AnswerValue], capturedAt: Date, notes: String?)] = []
    private(set) var fixes:
        [(itemId: String, rowVersion: Int, answers: [String: AnswerValue], capturedAt: Date, notes: String?)] = []
    private(set) var discarded: [UUID] = []
    private(set) var sent: [LoggedEntry] = []
    private(set) var undone: [(UUID, EntryScope)] = []
    /// The item's row version as the store has it (each fix moves it).
    var storedRowVersion = 3
    /// Holds `sendNow` until `release()` (overlapping saves); `whileHeld` runs as it starts.
    var holdSend = false
    var whileHeld: (@MainActor () -> Void)?
    private var held: [CheckedContinuation<Void, Never>] = []

    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func log(_ topic: EntryTopic, answers: [String: AnswerValue], capturedAt: Date?, notes: String?)
        async throws -> LoggedEntry
    {
        if let logError { throw logError }
        guard let scope else { throw EntryWriteError.scopeChanged }
        logged.append((answers, capturedAt ?? .distantPast, notes))
        return LoggedEntry(id: UUID(), scope: scope)
    }

    func sendNow(_ entry: LoggedEntry, wait: Duration) async -> EntryDelivery {
        sent.append(entry)
        if holdSend {
            whileHeld?()
            await withCheckedContinuation { held.append($0) }
        }
        return entry.scope == scope ? delivery : .queued
    }

    func undoLog(_ entryId: UUID, in scope: EntryScope) async throws -> Bool {
        guard scope == self.scope else { throw EntryWriteError.scopeChanged }
        undone.append((entryId, scope))
        return true
    }

    func undoDelete(_ entryId: UUID, in scope: EntryScope) async throws -> Bool { true }

    func discard(_ entry: LoggedEntry) async throws {
        guard entry.scope == scope else { throw EntryWriteError.scopeChanged }
        discarded.append(entry.id)
    }

    func fix(
        itemId: String, rowVersion: Int, topic: EntryTopic, answers: [String: AnswerValue], capturedAt: Date,
        notes: String?, in scope: EntryScope
    ) async throws -> LoggedEntry {
        guard scope == self.scope else { throw EntryWriteError.scopeChanged }
        fixes.append((itemId, rowVersion, answers, capturedAt, notes))
        storedRowVersion += 1
        return LoggedEntry(id: UUID(uuidString: itemId)!, scope: scope)
    }

    func rowVersion(itemId: String, in scope: EntryScope) async throws -> Int? {
        guard scope == self.scope else { throw EntryWriteError.scopeChanged }
        return storedRowVersion
    }

    func failure(_ error: any Error) -> EntryWriteFailure {
        switch error {
        case EntryWriteError.scopeChanged: .scopeChanged
        default: .message("\(error)")
        }
    }
}

/// A toast as the tests compare it.
struct RecordToast: Equatable {
    var title: String
    var undo: Bool
}

struct RecordBoom: Error {}

@MainActor @Suite struct RecordModelTests {
    let clock = RecordClock()
    let writer = RecordFakeWriter()
    let center: ToastCenter
    let toasts: EntryToasts
    let sleeper = Sleeper()

    init() {
        let sleeper = sleeper
        center = ToastCenter(sleep: { try await sleeper.sleep($0) })
        toasts = EntryToasts(center: center, writer: writer)
    }

    /// The toasts shown, as (title, has Undo).
    var shown: [RecordToast] { center.items.map { RecordToast(title: $0.toast.title, undo: $0.toast.action != nil) } }

    func model(_ topic: Topic = workout, _ mode: RecordModel.Mode = .new(last: nil), another: Bool = false)
        -> RecordModel
    {
        let clock = clock
        return RecordModel(
            topic: topic, mode: mode, writer: writer, toasts: toasts, logAnother: another, now: { clock.now })
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
        // Untouched, "captured at" is when the form opened (the PWA's), not the moment of Save.
        #expect(writer.logged.first?.capturedAt == start)
        #expect(writer.logged.first?.notes == nil)
        #expect(shown == [RecordToast(title: "Logged Workout", undo: true)])
        #expect(!model.hasUnsavedChanges && !model.isSaving)
    }

    @Test func aQueuedEntrySaysItWillSync() async {
        writer.delivery = .queued
        let model = model()
        fill(model)
        #expect(await model.save() == .leave)
        #expect(shown == [RecordToast(title: "Saved on this device", undo: true)])
    }

    @Test func anInvalidFormWritesNothing() async {
        let model = model()
        model.form.change("type", to: .text("run"))
        #expect(await model.save() == .stay)
        #expect(writer.logged.isEmpty && shown.isEmpty)
        #expect(model.form.errors["duration"] == "Required")
    }

    @Test func aRejectedEntryGoesBackOnTheFormAndLeavesTheQueue() async throws {
        writer.delivery = .failed(
            "422",
            problem: Problem(
                code: .invalidAnswers, detail: "Some answers need attention",
                errors: [
                    FieldIssue(location: [.key("answers"), .key("duration")], message: "Must be at most 120 min"),
                    FieldIssue(location: [.key("notes")], message: "Too long"),
                ]))
        let model = model()
        fill(model)
        #expect(await model.save() == .stay)
        #expect(writer.discarded.count == 1 && writer.discarded == writer.sent.map(\.id))
        #expect(model.form.errors["duration"] == "Must be at most 120 min")
        #expect(model.form.banner?.message == "Some answers need attention")
        #expect(model.metaErrors == [.notes: "Too long"])
        #expect(model.showsDetails)
        #expect(shown.isEmpty)
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
        #expect(shown == [RecordToast(title: "Logged Workout", undo: true)])
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
        #expect(shown == [RecordToast(title: "Couldn’t log Workout", undo: false)])
        #expect(model.hasUnsavedChanges)
    }

    @Test func anEntryDeletedMeanwhileIsNotSaved() async {
        writer.delivery = .notSaved
        let model = model()
        fill(model)
        #expect(await model.save() == .leave)
        #expect(shown == [RecordToast(title: "Not saved", undo: false)])
    }

    @Test func aSingleChipTopicSavesOnPick() async throws {
        let model = model(mood)
        #expect(model.form.autoSaveKey == "mood")
        let body = try #require(model.form.change("mood", to: .text("good")))
        #expect(await model.autoSave(body))
        #expect(writer.logged.first?.answers == ["mood": .string("good")])
        #expect(shown == [RecordToast(title: "Logged Mood", undo: true)])

        writer.delivery = .failed("Server error", problem: nil)
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
        #expect(shown == [RecordToast(title: "Logged Workout", undo: false)])
    }

    @Test func aFixRejectedAgainStaysAndKeepsTheItem() async {
        writer.delivery = .failed("422", problem: rejected)
        let model = model(workout, .fix(fix(problem: rejected)))
        model.form.change("duration", to: .text("700"))
        #expect(await model.save() == .stay)
        #expect(writer.discarded.isEmpty, "a fix is only discarded from the sync sheet")
        #expect(model.form.errors["duration"] == "Must be at most 600 min")
        #expect(shown.isEmpty)
    }

    @Test func aSecondFixAfterARejectionUsesTheItemsNewVersion() async {
        writer.delivery = .failed("422", problem: rejected)
        let model = model(workout, .fix(fix(problem: rejected)))
        // Valid here, refused by the server twice.
        model.form.change("duration", to: .text("500"))
        #expect(await model.save() == .stay)
        model.form.change("duration", to: .text("400"))
        #expect(await model.save() == .stay)
        writer.delivery = .sent
        model.form.change("duration", to: .text("60"))
        #expect(await model.save() == .leave)
        // Each fix used the version the previous one left (3, then 4, then 5), so none misses.
        #expect(writer.fixes.map(\.rowVersion) == [3, 4, 5])
        #expect(writer.fixes.last?.answers == ["type": .string("run"), "duration": .int(60)])
    }

    @Test func aRefusalWithoutAProblemIsShownInBothModes() async {
        writer.delivery = .failed("Rejected (400)", problem: nil)
        let model = model()
        fill(model)
        #expect(await model.save() == .stay)
        #expect(model.rejectionMessage == "Rejected (400)")
        #expect(writer.discarded.count == 1)
        writer.delivery = .sent
        #expect(await model.save() == .leave)
        #expect(model.rejectionMessage == nil)

        writer.delivery = .failed("Rejected (400)", problem: nil)
        let fixing = self.model(workout, .fix(fix(problem: rejected)))
        fixing.form.change("duration", to: .text("60"))
        #expect(await fixing.save() == .stay)
        #expect(fixing.rejectionMessage == "Rejected (400)")
    }

    @Test func overlappingSavesWriteOnceAndEditingWaits() async {
        writer.holdSend = true
        let model = model()
        fill(model)
        let first = Task { await model.save() }
        while writer.sent.isEmpty { await Task.yield() }
        #expect(model.isSaving, "the view disables editing while this is true")
        #expect(await model.save() == .stay, "a second Save while saving does nothing")
        writer.release()
        #expect(await first.value == .leave)
        #expect(writer.logged.count == 1 && !model.isSaving)
    }

    // MARK: Store identity and lifetime

    /// The Undo in the toast belongs to the app's `EntryToasts`, not the screen: tapped after the
    /// screen (and its model) are gone, it still undoes the entry, in the store it went to.
    @Test func undoWorksAfterTheScreenIsGone() async throws {
        var model: RecordModel? = self.model()
        fill(model!)
        #expect(await model!.save() == .leave)
        let entry = try #require(writer.sent.first)
        weak let released = model
        model = nil
        #expect(released == nil, "the screen's model is gone")
        center.performAction(try #require(center.items.last?.id))
        for _ in 0..<1000 where writer.undone.isEmpty { await Task.yield() }
        #expect(writer.undone.map(\.0) == [entry.id])
        #expect(writer.undone.map(\.1) == [EntryScope("server-A/1")])
        #expect(shown.last == RecordToast(title: "Undone", undo: false))
    }

    /// The store changes (a server switch or a reset) between the enqueue and the send: the entry
    /// waits in its own store (queued, not reported as sent or refused there), and its Undo is
    /// refused instead of reaching the new store.
    @Test func aStoreChangeBetweenLogAndSendKeepsTheEntryInItsStore() async throws {
        writer.holdSend = true
        writer.whileHeld = { [writer] in writer.scope = EntryScope("server-B/1") }
        let model = model()
        fill(model)
        let saving = Task { await model.save() }
        while writer.sent.isEmpty { await Task.yield() }
        writer.release()
        #expect(await saving.value == .leave)
        #expect(writer.sent.first?.scope == EntryScope("server-A/1"))
        #expect(shown == [RecordToast(title: "Saved on this device", undo: true)])
        #expect(writer.discarded.isEmpty)
        center.performAction(try #require(center.items.last?.id))
        for _ in 0..<1000 where shown.count < 2 { await Task.yield() }
        #expect(writer.undone.isEmpty)
        #expect(shown.last?.title == "Couldn’t undo")
    }

    /// A fix acts in the store its item was read from: after a switch it is refused, and nothing
    /// is written to the new store.
    @Test func aFixAfterAStoreChangeIsRefused() async {
        let model = model(workout, .fix(fix(problem: rejected)))
        writer.scope = EntryScope("server-B/1")
        model.form.change("duration", to: .text("60"))
        #expect(await model.save() == .stay)
        #expect(writer.fixes.isEmpty)
        #expect(shown.last?.title == "Couldn’t log Workout")
        #expect(model.hasUnsavedChanges)
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
