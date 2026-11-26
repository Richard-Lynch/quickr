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
///   detail redirects to the run). `holdsEditTimes` says one of the entry's removes is being
///   enqueued or still queued: Edit times waits for it, since a timing edit would void it
///   (`run_edited`).
/// - **Refused here** (nothing enqueued): `onRefused` gets what to tell the user, the PWA's
///   words ("That can’t be removed now", "This run can’t be resumed now").
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
    /// A remove of the entry's run is queued (pending, in flight or uncertain): Edit times waits
    /// for its ack, as saving times over the projection would void it (`run_edited`).
    public private(set) var removeQueued = false
    /// A Remove tapped here is being enqueued.
    public private(set) var removing = false
    /// Edit times waits: a remove is being enqueued or is queued (an edit would void it).
    public var holdsEditTimes: Bool { removing || removeQueued }
    /// Told what to say when a Remove or Resume run wasn't enqueued (the screen shows a toast).
    @ObservationIgnored public var onRefused: (@MainActor (String) -> Void)?

    public static let removeRefused = "That can’t be removed now"
    public static let resumeRefused = "This run can’t be resumed now"

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

    /// Reads the topic's local runs and the outbox (the entry's queued removes) until cancelled.
    public func observe() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeRuns() }
            group.addTask { await self.observeRemoves() }
        }
    }

    private func observeRuns() async {
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

    /// Reads `removeQueued` once: call it before the screen shows, so Edit times is never offered
    /// over a remove queued earlier while `observe()` hasn't read the outbox yet.
    public func readQueuedRemove() async throws {
        removeQueued = queuesRemove(try await store.outbox.items(topicId: topicId.wireString))
    }

    private func observeRemoves() async {
        do {
            for try await snapshot in store.observeOutbox(refresh: refresh?.stream()) {
                removeQueued = queuesRemove(snapshot.items)
            }
        } catch {}
    }

    /// `items` hold an active `remove` of the entry's run.
    private func queuesRemove(_ items: [OutboxItem]) -> Bool {
        let runId = entry.entry.id.wireString
        return items.contains { item in
            item.kind == .runEvent && item.state.isActive && item.entityId.lowercased() == runId
                && (try? item.runEventPayload())??.type == .remove
        }
    }

    /// Sends the row's remove, after its confirmation. True when it was enqueued; otherwise
    /// `onRefused` hears ``removeRefused``.
    @discardableResult
    public func remove(_ remove: EntryTimingModel.Remove) async -> Bool {
        var sent = false
        if remove.enabled, entry.entry.timing.map({ Self.targets($0).contains(remove.target) }) == true {
            removing = true
            defer { removing = false }
            sent =
                await runActions.remove(runId: entry.entry.id.wireString, topicId: topicId, target: remove.target)
                != nil
        }
        // Held at once, not only when the outbox observation catches up.
        if sent { removeQueued = true } else { onRefused?(Self.removeRefused) }
        return sent
    }

    /// Sends Resume run's reopen. True when it was enqueued: go to the run, which shows
    /// "Resuming…" without controls until the ack. Otherwise `onRefused` hears ``resumeRefused``.
    @discardableResult
    public func resume(now: Date) async -> Bool {
        var sent = false
        if offersResume(now: now) {
            sent = await runActions.reopen(runId: entry.entry.id.wireString, topicId: topicId) != nil
        }
        if !sent { onRefused?(Self.resumeRefused) }
        return sent
    }

    /// Every target the timing's rows offer an enabled Remove for.
    static func targets(_ timing: Timing) -> Set<String> {
        Set(
            EntryTimingModel.rows(timing).compactMap { row in
                EntryTimingModel.remove(row, in: timing).flatMap { $0.enabled ? $0.target : nil }
            })
    }
}
