import Foundation
import QuickrCore
import QuickrUI
import Testing

private let start = Date(timeIntervalSince1970: 1_790_000_000)

/// Version 2 (current): type and duration. Version 1 had a "note" and offered "swim", archived since.
private let typeQuestion = Question(
    key: "type", label: "Type",
    kind: .choice(
        .init(options: [
            EnumOption(value: "run", label: "Run"), EnumOption(value: "yoga", label: "Yoga"),
            EnumOption(value: "swim", label: "Swim", archived: true),
        ])))
private let duration = Question(key: "duration", label: "Duration", kind: .int(.init(min: 1, max: 600, unit: "min")))
private let note = Question(key: "note", label: "Note", required: false, kind: .string(.init()))

private let workout = Topic(
    id: UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c10")!, slug: "workout", name: "Workout",
    currentVersion: 2, revision: 1, questionCount: 2, createdAt: start, updatedAt: start,
    questions: [typeQuestion, duration])
private let version1 = [typeQuestion, duration, note]

private func entry(version: Int = 2, answers: [String: AnswerValue], notes: String = "") -> Entry {
    Entry(
        id: UUID(uuidString: "00000000-0000-4000-8000-0000000000e1")!, topicId: workout.id, version: version,
        revision: 4, source: "ios", channel: .ios, capturedAt: start.addingTimeInterval(-3600),
        createdAt: start.addingTimeInterval(-3600), updatedAt: start, notes: notes, answers: answers)
}

/// The edit screen's writer: records updates, or throws what the test sets.
@MainActor
final class EditFakeWriter: EntryEditing {
    var error: (any Error)?
    private(set) var updates: [(entryId: UUID, patch: EntryPatch, baseRevision: Int?, scope: EntryScope)] = []
    private(set) var fixes: [(itemId: String, rowVersion: Int, patch: EntryPatch, scope: EntryScope)] = []
    /// The refused item's row version as the store has it.
    var storedRowVersion = 7

    func update(entryId: UUID, topicId: UUID, patch: EntryPatch, baseRevision: Int?, in scope: EntryScope)
        async throws
    {
        if let error { throw error }
        updates.append((entryId, patch, baseRevision, scope))
    }

    func fixUpdate(
        itemId: String, rowVersion: Int, entryId: UUID, topicId: UUID, patch: EntryPatch, in scope: EntryScope
    ) async throws {
        if let error { throw error }
        fixes.append((itemId, rowVersion, patch, scope))
    }

    func rowVersion(itemId: String, in scope: EntryScope) async throws -> Int? { storedRowVersion }

    func failure(_ error: any Error) -> EntryWriteFailure {
        switch error {
        case let error as EntryWriteError where error == .scopeChanged: .scopeChanged
        case is Deleted: .notSaved
        default: .message(String(describing: error))
        }
    }

    /// Stands in for `OutboxError.entryDeleted` (C0).
    struct Deleted: Error {}
}

@MainActor
@Suite struct EditModelTests {
    let writer = EditFakeWriter()
    let center = ToastCenter()
    let scope = EntryScope("server-A/1")

    func model(
        _ entry: Entry, questions: [Question] = [typeQuestion, duration], localOnly: Bool = false, fix: EditFix? = nil
    ) -> EditModel {
        EditModel(
            topic: workout, entry: entry, questions: questions, localOnly: localOnly, fix: fix, writer: writer,
            toasts: EntryToasts(center: center, writer: RecordFakeWriter()), scope: scope, now: { start })
    }

    @Test func opensWithTheEntryOnItsOwnVersion() {
        let m = model(entry(version: 1, answers: ["type": .string("swim"), "duration": .int(30)]), questions: version1)
        #expect(m.isOutdated, "logged against version 1")
        #expect(m.form.questions.map(\.key) == ["type", "duration", "note"], "version 1's questions")
        #expect(m.form.options(for: typeQuestion).map(\.value).contains("swim"), "its archived option stays offered")
        #expect(m.form.input(for: "duration") == .text("30"))
        #expect(!m.hasUnsavedChanges)
    }

    @Test func savesOnlyWhatChanged() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]))
        _ = m.form.change("duration", to: .text("45"))
        #expect(m.hasUnsavedChanges)
        #expect(await m.save() == .leave)
        let update = try! #require(writer.updates.first)
        #expect(update.patch == EntryPatch(answers: ["duration": .some(.int(45))]))
        #expect(update.baseRevision == 4, "the revision the user edited")
        #expect(update.scope == scope, "the store the entry was read from")
        #expect(center.items.last?.toast.title == "Entry updated")
        #expect(!m.hasUnsavedChanges)
    }

    @Test func clearingAnOptionalAnswerSendsNil() async {
        let m = model(
            entry(version: 1, answers: ["type": .string("run"), "duration": .int(30), "note": .string("hi")]),
            questions: version1)
        _ = m.form.change("note", to: .text(""))
        #expect(await m.save() == .leave)
        #expect(writer.updates.first?.patch == EntryPatch(answers: ["note": AnswerValue?.none]))
    }

    @Test func notesAndCapturedAt() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)], notes: "old"))
        m.notes = "  new  "
        m.capturedAt = start.addingTimeInterval(-7200)
        #expect(await m.save() == .leave)
        #expect(
            writer.updates.first?.patch == EntryPatch(capturedAt: start.addingTimeInterval(-7200), notes: "new"))
    }

    @Test func nothingChangedLeavesWithoutWriting() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]))
        m.capturedAt = m.entry.capturedAt  // touched, not moved
        #expect(await m.save() == .leave)
        #expect(writer.updates.isEmpty)
    }

    @Test func anEntryTheServerDoesntHaveYetHasNoBaseRevision() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]), localOnly: true)
        _ = m.form.change("type", to: .text("yoga"))
        #expect(await m.save() == .leave)
        #expect(writer.updates.first?.baseRevision == nil, "the outbox merges it into the queued create (K1)")
    }

    @Test func aDeletedEntrySaysSoAndDoesntRetry() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]))
        writer.error = EditFakeWriter.Deleted()
        _ = m.form.change("duration", to: .text("45"))
        #expect(await m.save() == .stay)
        #expect(m.isDeleted)
        #expect(m.errorMessage == "This entry was deleted")
        writer.error = nil
        #expect(await m.save() == .stay, "nothing to save into any more")
        #expect(writer.updates.isEmpty)
        #expect(!m.hasUnsavedChanges, "leaving loses nothing")
    }

    @Test func aServerSwitchRefusesTheSave() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]))
        writer.error = EntryWriteError.scopeChanged
        _ = m.form.change("duration", to: .text("45"))
        #expect(await m.save() == .stay)
        #expect(m.errorMessage == "The server changed since this entry was opened. Nothing was saved.")
        #expect(!m.isDeleted)
        #expect(m.hasUnsavedChanges, "the edit is still there")
    }

    @Test func invalidAnswersAndFutureTimesStay() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]))
        _ = m.form.change("duration", to: .text("9999"))
        #expect(await m.save() == .stay)
        #expect(writer.updates.isEmpty)

        _ = m.form.change("duration", to: .text("45"))
        m.capturedAt = start.addingTimeInterval(86_400 * 3)
        #expect(await m.save() == .stay)
        #expect(m.metaErrors[.capturedAt] != nil)
        #expect(m.showsDetails)
        #expect(writer.updates.isEmpty)
    }

    // MARK: - Source

    @Test func theSourceIsEditableHereAndChecked() async {
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(30)]))
        #expect(m.sourceIsEditable)
        m.source = "   "
        #expect(await m.save() == .stay)
        #expect(m.metaErrors[.source] == "Where did this come from? (e.g. phone)")
        m.source = " watch "
        #expect(await m.save() == .leave)
        #expect(writer.updates.first?.patch == EntryPatch(source: "watch"))
    }

    // MARK: - Fixing a refused edit (outbox.md §11)

    /// The refused edit set duration to 900 (over the max): the form shows it with the server's
    /// error on the field; correcting it replaces the item's changes, keeping every field it set.
    @Test func aRefusedEditIsFixedWithItsErrorsOnTheFields() async {
        let refused = Problem(
            code: .invalidAnswers, detail: "Some answers need attention",
            errors: [FieldIssue(location: [.key("answers"), .key("duration")], message: "At most 600")])
        // It set type and duration (and notes); only duration was wrong.
        let fix = EditFix(
            itemId: "item-1", rowVersion: 3,
            patch: EntryPatch(answers: ["duration": .some(.int(900)), "type": .some(.string("yoga"))], notes: "long"),
            problem: refused, message: "Some answers need attention")
        // The store shows the refused values (its overlay applies the failed edit).
        let m = model(entry(answers: ["type": .string("yoga"), "duration": .int(900)], notes: "long"), fix: fix)
        #expect(m.isFixing)
        #expect(m.form.errors["duration"] == "At most 600")
        #expect(m.fixMessage == nil, "the Problem is on the fields")

        _ = m.form.change("duration", to: .text("90"))
        #expect(await m.save() == .leave)
        #expect(writer.updates.isEmpty, "a fix replaces the refused item, it doesn't queue another")
        let sent = try! #require(writer.fixes.first)
        #expect(sent.itemId == "item-1" && sent.rowVersion == 3 && sent.scope == scope)
        // Type wasn't touched now, but the refused edit set it: it is still sent.
        #expect(sent.patch.answers == ["duration": .some(.int(90)), "type": .some(.string("yoga"))])
        #expect(sent.patch.notes == "long", "every field the refused edit set is still sent")
        #expect(center.items.last?.toast.title == "Entry updated")
    }

    /// The item changed meanwhile (a CAS miss): the save says so and picks up the new version, so
    /// the next save applies.
    @Test func aFixThatRacesPicksUpTheNewVersion() async {
        let fix = EditFix(
            itemId: "item-1", rowVersion: 3, patch: EntryPatch(answers: ["duration": .some(.int(900))]), problem: nil,
            message: "Rejected")
        let m = model(entry(answers: ["type": .string("run"), "duration": .int(900)]), fix: fix)
        #expect(m.fixMessage == "Rejected")
        writer.error = FixChanged()
        _ = m.form.change("duration", to: .text("90"))
        #expect(await m.save() == .stay)
        #expect(m.errorMessage != nil)
        writer.error = nil
        #expect(await m.save() == .leave)
        #expect(writer.fixes.first?.rowVersion == 7, "the store's version")
    }

    struct FixChanged: Error {}
}
