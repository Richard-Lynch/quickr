import Foundation
import QuickrCore
import QuickrUI
import Testing

/// Edit times' writer: records saves and answers with what the test sets.
@MainActor
final class FakeTimingWriter: EntryTimingWriting {
    private(set) var saves: [(edit: TimingDraft.Edit, revision: Int)] = []
    private(set) var reloads = 0
    var saveResult: TopicWriteOutcome<Entry>?
    var latest: Entry?
    /// The server's entry after a save: the edit's times at revision + 1.
    var steps: [TopicTimer.Step] = []

    func saveTiming(_ edit: TimingDraft.Edit, entryId: UUID, expectedRevision: Int) async -> TopicWriteOutcome<Entry> {
        saves.append((edit, expectedRevision))
        if let saveResult { return saveResult }
        guard var entry = latest else { return .failed("no entry") }
        entry.timing = edit.timing(steps: steps)
        entry.capturedAt = RunInstant.date(entry.timing!.endedAt)
        entry.revision = expectedRevision + 1
        latest = entry
        return .done(entry)
    }

    func latestEntry(entryId: UUID) async -> TopicWriteOutcome<Entry> {
        reloads += 1
        return latest.map { .done($0) } ?? .notFound
    }
}

private let now = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26

private func ms(_ hms: String) -> Int { RunInstant.parse("2026-10-23T\(hms)Z")! }

private let steps: [TopicTimer.Step] = [.init(key: "shower", label: "Shower"), .init(key: "dress", label: "Dress")]

/// Shower 7:00–7:04, Dress to 7:09.
private let timing = Timing(
    startedAt: ms("07:00:00"), endedAt: ms("07:09:00"), activeMs: 540_000, pausedMs: 0, complete: true, edited: false,
    segments: [
        RunSegment(
            kind: .step, step: "shower", label: "Shower", startedAt: ms("07:00:00"), endedAt: ms("07:04:00"),
            activeMs: 240_000, pausedMs: 0),
        RunSegment(
            kind: .step, step: "dress", label: "Dress", startedAt: ms("07:04:00"), endedAt: ms("07:09:00"),
            activeMs: 300_000, pausedMs: 0),
    ], skipped: [], pauses: [])

private let question = Question(key: "mood", label: "Mood", required: false, kind: .int(.init(min: 1, max: 5)))

private let topic = Topic(
    id: UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c11")!, slug: "morning", name: "Morning",
    currentVersion: 1, revision: 1, questionCount: 1, createdAt: now, updatedAt: now,
    timer: TopicTimer(steps: steps), questions: [question])

private let timedEntry = Entry(
    id: UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!, topicId: topic.id, version: 1, revision: 3,
    source: "ios", channel: .ios, capturedAt: RunInstant.date(ms("07:09:00")), createdAt: now, updatedAt: now,
    notes: "", answers: ["mood": .int(3)], timing: timing)

private let utc = TimingEditClock(timeZone: TimeZone(identifier: "UTC")!)

/// R10's model half (timers.md §3.8, §11.2): Edit times saves `{timing, expected_revision}` online,
/// never over a newer revision, and keeps the answer form's unsaved edits.
@MainActor @Suite struct TimingEditModelTests {
    let writer = FakeTimingWriter()
    let entryWriter = EditFakeWriter()
    let center = ToastCenter()

    init() {
        writer.latest = timedEntry
        writer.steps = steps
    }

    func editModel(localOnly: Bool = false) -> EditModel {
        EditModel(
            topic: topic, entry: timedEntry, questions: [question], localOnly: localOnly, writer: entryWriter,
            toasts: EntryToasts(center: center, writer: RecordFakeWriter()), scope: EntryScope("server-A/1"),
            timerSteps: steps, timingWriter: writer, timingClock: utc, now: { now })
    }

    func editor(_ m: EditModel) throws -> TimingEditModel {
        m.openTimingEditor()
        return try #require(m.timingEditor)
    }

    @Test func aTimedEntryHidesCapturedAtAndSourceAndNeverSendsThem() async {
        let m = editModel()
        #expect(m.isTimed)
        #expect(!m.showsCapturedAt)
        #expect(!m.showsSource)
        m.capturedAt = now
        m.notes = "Late start"
        #expect(await m.save() == .leave)
        let patch = entryWriter.updates.first?.patch
        #expect(patch == EntryPatch(notes: "Late start"), "captured_at is hidden and never sent (a 422 otherwise)")
    }

    @Test func anUntouchedSaveSendsTheExactTimesAgainstTheOpenedRevision() async throws {
        let m = editModel()
        let editor = try editor(m)
        editor.draft.segments[0].endedAt = utc.text(ms("07:03:00"))
        await m.saveTiming()
        let save = try #require(writer.saves.first)
        #expect(save.revision == 3)
        #expect(save.edit.startedAt == ms("07:00:00"))
        let ends = save.edit.segments.map(\.endedAt)
        #expect(ends == [ms("07:03:00"), ms("07:09:00")])
        let total = m.entry.timing?.activeMs
        #expect(total == 540_000)
        let first = m.entry.timing?.segments.first?.activeMs
        #expect(first == 180_000, "the entry shows its new times")
        #expect(m.timingEditor == nil, "the sheet closes")
        #expect(m.entry.revision == 4)
        let title: String? = center.items.last?.toast.title
        #expect(title == "Times updated")
    }

    @Test func aStaleRevisionStopsSavingUntilTheTimesAreReloaded() async throws {
        let m = editModel()
        let editor = try editor(m)
        writer.saveResult = .staleRevision
        await m.saveTiming()
        #expect(editor.isStale)
        #expect(m.timingEditor != nil, "the sheet stays, saying so")
        // Saving again sends nothing: a stale draft is never saved.
        await m.saveTiming()
        #expect(writer.saves.count == 1)
        // Reload: the server's times at its revision, as a fresh draft.
        var newer = timedEntry
        newer.revision = 5
        writer.latest = newer
        writer.saveResult = nil
        await editor.reload()
        #expect(!editor.isStale)
        #expect(editor.revision == 5)
        await m.saveTiming()
        let last = writer.saves.last?.revision
        #expect(last == 5)
        #expect(m.timingEditor == nil)
    }

    @Test func aNewerRevisionSeenWhileOpenMakesItStale() async throws {
        let m = editModel()
        let editor = try editor(m)
        var elsewhere = timedEntry
        elsewhere.revision = 4
        m.entryChanged(elsewhere)
        #expect(editor.isStale)
        await m.saveTiming()
        #expect(writer.saves.isEmpty, "never saved against a revision it wasn't made from")
        #expect(editor.draft.segments.count == 2, "the draft isn't replaced silently")
    }

    @Test func theServersFieldErrorsShowUntilTheFieldIsEdited() async throws {
        let m = editModel()
        let editor = try editor(m)
        writer.saveResult = .rejected(
            Problem(
                code: .invalidRequest, detail: "invalid timing",
                errors: [
                    .init(
                        location: [.key("body"), .key("timing"), .key("segments"), .index(1), .key("ended_at")],
                        message: "before the segment's start")
                ]))
        await m.saveTiming()
        let shown = editor.error("segments.1.ended_at")
        #expect(shown == "Before the segment's start")
        editor.draft.segments[1].endedAt = editor.draft.segments[1].endedAt + " "
        #expect(editor.error("segments.1.ended_at") == nil)
    }

    @Test func aClientRefusalSendsNothing() async throws {
        let m = editModel()
        let editor = try editor(m)
        editor.draft.segments[1].endedAt = "2026-10-23 06:00:00"
        await m.saveTiming()
        #expect(writer.saves.isEmpty)
        let error = editor.error("segments.1.ended_at")
        #expect(error == "Before the segment’s start")
    }

    @Test func anEditTimesSaveKeepsUnsavedAnswersAndRebasesThem() async throws {
        let m = editModel()
        _ = m.form.change("mood", to: .text("5"))
        m.notes = "Slow"
        let editor = try editor(m)
        _ = editor
        await m.saveTiming()
        let input = m.form.input(for: "mood")
        #expect(input == .text("5"), "the answer edit stays")
        #expect(m.notes == "Slow")
        #expect(m.changedElsewhere == nil, "its own save isn't a change elsewhere")
        // The store's copy of the save arrives too: same answers, nothing to say.
        if let saved = writer.latest { m.entryChanged(saved) }
        #expect(m.changedElsewhere == nil)
        #expect(await m.save() == .leave)
        let base = entryWriter.updates.first?.baseRevision
        #expect(base == 4, "the answers are saved on the revision the times were")
    }

    @Test func aChangeElsewhereWhileTheFormIsDirtyAsksToReload() {
        let m = editModel()
        _ = m.form.change("mood", to: .text("5"))
        var elsewhere = timedEntry
        elsewhere.revision = 4
        elsewhere.answers = ["mood": .int(1)]
        m.entryChanged(elsewhere)
        #expect(m.changedElsewhere != nil)
        let kept = m.form.input(for: "mood")
        #expect(kept == .text("5"), "the edits are kept until Reload")
        m.reloadChangedEntry()
        let reloaded = m.form.input(for: "mood")
        #expect(reloaded == .text("1"))
        #expect(m.changedElsewhere == nil)
        #expect(!m.hasUnsavedChanges)
    }

    @Test func aCleanFormTakesAChangeElsewhere() {
        let m = editModel()
        var elsewhere = timedEntry
        elsewhere.revision = 4
        elsewhere.answers = ["mood": .int(2)]
        m.entryChanged(elsewhere)
        #expect(m.changedElsewhere == nil)
        let input = m.form.input(for: "mood")
        #expect(input == .text("2"))
    }

    @Test func editTimesWaitsForTheServerToHaveTheEntry() {
        let m = editModel(localOnly: true)
        #expect(m.timingEditUnavailable == "Edit times once this run has synced.")
        m.openTimingEditor()
        #expect(m.timingEditor == nil)
    }
}
