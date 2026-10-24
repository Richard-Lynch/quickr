import Foundation
import Observation
import QuickrCore

/// Edit times' online-only calls (timers.md §3.8), bound to the store the entry was read from
/// (the app's `SessionTopicWriter` over `TopicWrites`).
@MainActor
public protocol EntryTimingWriting: AnyObject {
    /// `PATCH {timing, expected_revision}`: the entry as the server saved it.
    func saveTiming(_ edit: TimingDraft.Edit, entryId: UUID, expectedRevision: Int) async -> TopicWriteOutcome<Entry>
    /// "Reload times": the entry as the server holds it now.
    func latestEntry(entryId: UUID) async -> TopicWriteOutcome<Entry>
}

/// The Edit times sheet (the PWA's `TimingSection` and `TimingEditor`): the times as they were when
/// it opened, edited as text, checked with the server's rules and saved against the revision they
/// came from.
///
/// If the entry changed since it opened (a 409 `stale_revision`, or a newer revision seen while it
/// is open, ``entryChanged(revision:)``), saving stops: "These times changed since you opened
/// them", with Reload times. A draft is never re-based silently, nor saved against a revision it
/// wasn't made from. The server's 422 field errors show on the fields they name until each is
/// edited.
@MainActor @Observable
public final class TimingEditModel {
    public static let staleTitle = "These times changed since you opened them"
    public static let staleText = "Reloading shows the latest times and discards your edits here."

    public let entryId: UUID
    /// The run's version's steps: the labels and the segments' choices.
    public let steps: [TopicTimer.Step]
    /// The revision the times came from: what a save is checked against.
    public private(set) var revision: Int
    public var draft: TimingDraft {
        didSet { touch(changedFields(from: oldValue)) }
    }
    /// Save was tapped: the client's errors show from then on.
    public private(set) var submitted = false
    public private(set) var serverErrors: [String: String] = [:]
    public private(set) var serverMessage: String?
    public private(set) var isSaving = false
    public private(set) var isReloading = false
    /// A 409 `stale_revision` answered a save.
    public private(set) var conflict = false
    /// The newest revision of the entry seen since opening.
    public private(set) var latestRevision: Int
    /// Fields edited since the server's errors came: theirs no longer show.
    @ObservationIgnored private var touched: Set<String> = []
    @ObservationIgnored private let writer: any EntryTimingWriting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clock: TimingEditClock

    public init(
        entryId: UUID, timing: Timing, revision: Int, steps: [TopicTimer.Step], writer: any EntryTimingWriting,
        clock: TimingEditClock = .current, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.entryId = entryId
        self.steps = steps
        self.revision = revision
        latestRevision = revision
        self.writer = writer
        self.clock = clock
        self.now = now
        draft = TimingDraft(timing: timing, clock: clock)
    }

    /// The entry's revision changed while the sheet is open. Recorded even while a save is out:
    /// if the save succeeds the sheet closes, and if it fails the draft is stale.
    public func entryChanged(revision: Int) {
        latestRevision = Swift.max(latestRevision, revision)
    }

    /// Saving is off until the times are reloaded.
    public var isStale: Bool { conflict || latestRevision != revision }

    public var checked: TimingDraft.Checked {
        draft.check(steps: steps, now: RunInstant.milliseconds(now()))
    }

    /// A field's message: the client's once Save was tapped, else the server's until it's edited.
    public func error(_ path: String) -> String? {
        (submitted ? checked.errors[path] : nil) ?? (touched.contains(path) ? nil : serverErrors[path])
    }

    /// The form's own message (no segment left, or the server's about the whole timing).
    public var formError: String? { error("") ?? error("segments") }

    /// Steps of the version without a segment: each can be ticked "Skipped".
    public var unreached: [TopicTimer.Step] {
        let used = Set(draft.segments.compactMap(\.step))
        return steps.filter { !used.contains($0.key) }
    }

    /// "Save times": the entry as saved, or nil (the sheet stays, with what went wrong).
    public func save() async -> Entry? {
        guard !isSaving, !isReloading else { return nil }
        submitted = true
        guard !isStale, let edit = checked.edit else { return nil }
        isSaving = true
        defer { isSaving = false }
        serverMessage = nil
        let outcome = await writer.saveTiming(edit, entryId: entryId, expectedRevision: revision)
        switch outcome {
        case .done(let entry):
            serverErrors = [:]
            return entry
        case .staleRevision:
            conflict = true
            serverErrors = [:]
        case .rejected(let problem?) where problem.code == .staleRevision:
            conflict = true
            serverErrors = [:]
        case .rejected(let problem?):
            var errors: [String: String] = [:]
            for issue in problem.errors {
                guard let path = TimingDraft.field(forServerPath: ProblemMapping.path(issue.location)) else { continue }
                if errors[path] == nil { errors[path] = ProblemMapping.cleanMessage(issue.message) }
            }
            serverErrors = errors
            touched = []
            serverMessage = ProblemMapping.banner(for: problem)
        default:
            serverMessage = outcome.message ?? "The server refused the times."
        }
        return nil
    }

    /// "Reload times": the server's times now, as a fresh draft (this one is discarded).
    public func reload() async {
        guard !isReloading, !isSaving else { return }
        isReloading = true
        defer { isReloading = false }
        let outcome = await writer.latestEntry(entryId: entryId)
        guard case .done(let entry) = outcome else {
            if case .rejected(let problem?) = outcome {
                serverMessage = ProblemMapping.banner(for: problem)
            } else {
                serverMessage = outcome.message ?? "Could not reload the times."
            }
            return
        }
        guard let timing = entry.timing else {
            serverMessage = "This entry has no times any more."
            return
        }
        open(timing, revision: entry.revision)
    }

    /// A fresh draft of `timing` at `revision`: no errors, nothing stale.
    func open(_ timing: Timing, revision: Int) {
        self.revision = revision
        // A newer revision seen meanwhile still makes the reloaded times stale.
        latestRevision = Swift.max(latestRevision, revision)
        conflict = false
        submitted = false
        serverErrors = [:]
        serverMessage = nil
        draft = TimingDraft(timing: timing, clock: clock)
        touched = []
    }

    private func touch(_ paths: Set<String>) { touched.formUnion(paths) }

    /// The field paths whose text or choice differs from `old` (list edits touch the list).
    private func changedFields(from old: TimingDraft) -> Set<String> {
        var out: Set<String> = []
        if old.startedAt != draft.startedAt { out.insert("started_at") }
        if old.segments.map(\.id) != draft.segments.map(\.id) { out.insert("segments") }
        for (i, segment) in draft.segments.enumerated() where i < old.segments.count {
            if old.segments[i].endedAt != segment.endedAt { out.insert("segments.\(i).ended_at") }
            if old.segments[i].step != segment.step { out.insert("segments.\(i).step") }
        }
        if old.skipped != draft.skipped { out.formUnion(draft.skipped.indices.map { "skipped.\($0)" }) }
        if old.pauses.map(\.id) != draft.pauses.map(\.id) { out.insert("pauses") }
        for (i, pause) in draft.pauses.enumerated() where i < old.pauses.count {
            if old.pauses[i].start != pause.start { out.insert("pauses.\(i).start") }
            if old.pauses[i].end != pause.end { out.insert("pauses.\(i).end") }
        }
        return out
    }
}
