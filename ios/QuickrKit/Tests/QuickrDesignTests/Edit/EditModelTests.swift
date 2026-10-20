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

    func update(entryId: UUID, topicId: UUID, patch: EntryPatch, baseRevision: Int?, in scope: EntryScope)
        async throws
    {
        if let error { throw error }
        updates.append((entryId, patch, baseRevision, scope))
    }

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
        _ entry: Entry, questions: [Question] = [typeQuestion, duration], localOnly: Bool = false
    ) -> EditModel {
        EditModel(
            topic: workout, entry: entry, questions: questions, localOnly: localOnly, writer: writer,
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
}
