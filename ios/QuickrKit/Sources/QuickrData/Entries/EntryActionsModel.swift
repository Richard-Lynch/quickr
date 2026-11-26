import Foundation
import Observation
import QuickrCore

/// The entry detail's run actions (content-display.md §3.2): one-tap Remove on lap and pause rows,
/// and Resume run. Both go through `RunActions` (the write façade `RunWrites`, then a flush) with
/// their targets taken from the entry's own `timing` (A7, D-3), so they queue offline like any run
/// event; neither needs the run to be in the local view.
///
/// - **Remove** sends `remove(target:)`: a lap row's `segments[i].event_id`, a pause row's
///   `pauses[j].id` (`EntryTimingModel.remove`). While it is queued the store shows the entry
///   with its timing re-projected and pending (A14, `StoreView.entries`); feed that in with
///   `entryChanged(_:)` and the rows follow.
/// - **Resume run** sends `reopen` (`target: timing.terminal_id`, or null from a pre-v2 timing:
///   `RunWrites` takes it from the stored entry, A12). The store then projects a "resuming" run
///   and hides the entry (OQ-14): the screen goes to the run.
/// - **The topic's local runs** (`observe()`): Resume is hidden while the topic has a locally open
///   or finishing run (A15), and `isOpenHere` says the entry is itself such a run (OQ-14: the
///   detail redirects to the run).
@MainActor @Observable
public final class EntryActionsModel {
    public let topicId: UUID
    /// The entry as the store shows it now (projected by queued removes).
    public private(set) var entry: ViewEntry
    /// The topic has a locally open or finishing run (A15).
    public private(set) var topicHasLocalRun = false
    /// The entry's own run is open or finishing here (OQ-14): the run represents it.
    public private(set) var isOpenHere = false
    /// The topic's local runs have been read once (until then Resume stays hidden).
    public private(set) var runsRead = false

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let refresh: RefreshSignal?
    @ObservationIgnored private let runActions: RunActions

    public init(entry: ViewEntry, store: LocalStore, refresh: RefreshSignal?, runActions: RunActions) {
        self.entry = entry
        topicId = entry.entry.topicId
        self.store = store
        self.refresh = refresh
        self.runActions = runActions
    }

    /// Not yet the server's: a queued remove's projection, or any other queued or failed change.
    public var isPending: Bool { entry.syncState != .synced }

    /// The store's latest for this entry (an observation of the topic's entries).
    public func entryChanged(_ latest: ViewEntry) {
        guard latest.entry.id == entry.entry.id else { return }
        entry = latest
    }

    /// The times to show beside a form's copy of the entry (`shown`): the store's, unless the
    /// form's is newer (an Edit times save not yet back from the store). A queued remove's
    /// projection keeps the revision, so it shows even while the form holds an older copy (fixing
    /// a refused edit ignores the store's updates).
    public func timing(over shown: Entry) -> Timing? {
        guard shown.id == entry.entry.id, entry.entry.revision >= shown.revision else { return shown.timing }
        return entry.entry.timing
    }

    /// Remove on `row`, or nil (`EntryTimingModel.remove`).
    public func removeAction(_ row: EntryTimingModel.Row) -> EntryTimingModel.Remove? {
        entry.entry.timing.flatMap { EntryTimingModel.remove(row, in: $0) }
    }

    /// Whether "Resume run" shows now (`EntryTimingModel.offersResume`), once the runs are read.
    public func offersResume(now: Date) -> Bool {
        runsRead
            && EntryTimingModel.offersResume(
                entry.entry, pending: isPending, topicHasLocalRun: topicHasLocalRun, now: now)
    }

    /// Reads the topic's local runs until cancelled.
    public func observe() async {
        let entryId = entry.entry.id.wireString
        do {
            for try await runs in store.observeLocalRuns(topicId: topicId, refresh: refresh?.stream()) {
                let live = runs.filter { $0.isOpen || $0.status == .finishing }
                topicHasLocalRun = !live.isEmpty
                isOpenHere = live.contains { $0.answers(to: entryId) }
                runsRead = true
            }
        } catch {}
    }

    /// Sends the row's remove, after its confirmation. True when it was enqueued.
    @discardableResult
    public func remove(_ remove: EntryTimingModel.Remove) async -> Bool {
        guard remove.enabled, entry.entry.timing.map({ Self.targets($0).contains(remove.target) }) == true else {
            return false
        }
        return await runActions.remove(runId: entry.entry.id.wireString, topicId: topicId, target: remove.target)
            != nil
    }

    /// Sends Resume run's reopen. True when it was enqueued: go to the run, which shows
    /// "Resuming…" without controls until the ack.
    @discardableResult
    public func resume(now: Date) async -> Bool {
        guard offersResume(now: now) else { return false }
        return await runActions.reopen(runId: entry.entry.id.wireString, topicId: topicId) != nil
    }

    /// Every target the timing's rows offer an enabled Remove for.
    static func targets(_ timing: Timing) -> Set<String> {
        Set(
            EntryTimingModel.rows(timing).compactMap { row in
                EntryTimingModel.remove(row, in: timing).flatMap { $0.enabled ? $0.target : nil }
            })
    }
}
