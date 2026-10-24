import Foundation
import GRDB
import QuickrCore

// The run's Live Activity on this device (timers.md §10.3), behind a protocol: ActivityKit runs
// only on a device (the app's `SystemRunActivityCenter`), and the rules here are tested with a
// fake centre on the host (R8).

/// One of this app's run activities, as ActivityKit has it.
public struct RunActivityRecord: Sendable, Hashable, Identifiable {
    public enum Phase: Sendable, Hashable {
        case pending, active, stale, ended, dismissed

        /// Showing and still updatable.
        public var isLive: Bool { self == .pending || self == .active || self == .stale }
    }

    public var id: String
    public var attributes: RunActivityAttributes
    public var state: RunActivityState
    /// Every update sets it 4 hours ahead (ours and the server's), so the latest is the most
    /// recently updated activity.
    public var staleDate: Date?
    public var phase: Phase

    public init(
        id: String, attributes: RunActivityAttributes, state: RunActivityState, staleDate: Date?, phase: Phase
    ) {
        self.id = id
        self.attributes = attributes
        self.state = state
        self.staleDate = staleDate
        self.phase = phase
    }
}

/// When an ended activity leaves the screen.
public enum RunActivityDismissal: Sendable, Hashable {
    case immediate
    case after(Date)
}

/// ActivityKit, as the rules use it.
public protocol RunActivityCenter: Sendable {
    /// The user allows Live Activities for the app (Settings ▸ quickR).
    func areActivitiesEnabled() async -> Bool
    func activities() async -> [RunActivityRecord]
    /// Starts one, with an update token. Throws when iOS refuses (the app is in the background,
    /// the limit is reached, activities are off).
    func request(_ attributes: RunActivityAttributes, _ state: RunActivityState, staleDate: Date) async throws
        -> String
    func update(id: String, _ state: RunActivityState, staleDate: Date) async
    func end(id: String, _ state: RunActivityState, dismissal: RunActivityDismissal) async
}

/// What the activities are reconciled with: the active store's server and its local view of runs
/// (timers.md §8.3), and the names of the topics with one.
public struct RunActivitySnapshot: Sendable, Hashable {
    public var serverId: String
    public var runs: [LocalRun]
    /// By topic id.
    public var topicNames: [UUID: String]

    public init(serverId: String, runs: [LocalRun], topicNames: [UUID: String]) {
        self.serverId = serverId
        self.runs = runs
        self.topicNames = topicNames
    }

    /// One read of `store`; nil until its bootstrap is complete (its view of runs would be
    /// partial, and reconciliation would end activities whose runs are still to come).
    public static func read(_ store: LocalStore) async throws -> RunActivitySnapshot? {
        let serverId = store.serverId
        return try await store.writer.read { db in
            let bootstrapped =
                try Bool.fetchOne(db, sql: "SELECT bootstrap_complete FROM sync_state WHERE id = 1") ?? false
            guard bootstrapped else { return nil }
            let runs = try RunOverlay.localRuns(db)
            var names: [UUID: String] = [:]
            for topicId in Set(runs.map(\.topicId)) {
                names[topicId] = try String.fetchOne(
                    db, sql: "SELECT name FROM topic WHERE id = ?", arguments: [topicId.wireString])
            }
            return RunActivitySnapshot(serverId: serverId, runs: runs, topicNames: names)
        }
    }

    /// The run a topic's activity shows: the run it shows (`runId`, its id or an alias) while
    /// that one is open or finishing; else the topic's open run (the activity follows it); else
    /// the shown run if it just closed here (a queued stop, finish or discard not acknowledged
    /// yet); else the newest finishing run; else the newest. The local view lists the server's
    /// runs newest first and then the queued starts, so "newest" is by start time.
    public func run(topicId: UUID, showing runId: String? = nil) -> LocalRun? {
        let mine = runs.filter { $0.topicId == topicId }
        let shown = runId.flatMap { id in mine.first { $0.answers(to: id) } }
        if let shown, shown.isOpen || shown.status == .finishing { return shown }
        if let open = mine.first(where: \.isOpen) { return open }
        if let shown { return shown }
        func newest(_ runs: [LocalRun]) -> LocalRun? { runs.max { $0.state.startedAt < $1.state.startedAt } }
        return newest(mine.filter { $0.status == .finishing }) ?? newest(mine)
    }

    /// The content state the view gives `run`. Nil when the pinned version's steps aren't stored
    /// here (a run started elsewhere): the labels and step positions would be wrong, so the
    /// activity keeps the server's.
    public static func state(_ run: LocalRun) -> RunActivityState? {
        guard let steps = run.steps else { return nil }
        return RunActivityContent.state(
            runId: run.id, revision: run.server?.revision ?? 0, status: run.status, state: run.state, steps: steps)
    }

    /// For a request when the steps aren't stored: no positions or next label, and marked
    /// `steps_unknown` so the activity offers a plain Next, never Lap. Updated once they are.
    static func stateWithoutSteps(_ run: LocalRun) -> RunActivityState {
        var state = RunActivityContent.state(
            runId: run.id, revision: run.server?.revision ?? 0, status: run.status, state: run.state, steps: [])
        state.stepsUnknown = true
        return state
    }
}

/// What to do to the activities.
public enum RunActivityAction: Sendable, Hashable {
    case request(RunActivityAttributes, RunActivityState)
    case update(id: String, RunActivityState)
    case end(id: String, RunActivityState, RunActivityDismissal)
}

/// The rules (timers.md §10.3, Reconciliation; T-LAPUSH L8), pure: on every app activation, after
/// every sync and after this device's own taps, compare the activities with the local view.
///
/// - **One per (server, topic).** Of several live ones, the most recently updated stays (the
///   latest `staleDate`, then the highest revision); the others end at once.
/// - **Open run:** update the activity when what it shows differs from the view. Not when the
///   activity is ahead: it shows a later server revision of the same run than this device holds,
///   with nothing of its own queued (another device's tap, pushed before this device synced).
/// - **Finishing:** end it with "Add details", dismissed after 15 minutes: the server stops
///   pushing to it (L8), so the device that finishes it updates it.
/// - **Stopped here** (a queued stop or finish): end it with "Saved · …", dismissed after 15
///   minutes. **Discarded:** end it at once.
/// - **No run:** stopped or discarded elsewhere, or a missed `end` push: end it at once.
/// - **Ended "Add details"** whose run has since been finished here: end it again with
///   "Saved · …"; finished elsewhere or discarded (no longer in the view): dismissed at once.
/// - **Start:** only when this device starts the run (`startFor`): iOS shows one for a run started
///   elsewhere by push-to-start, and a user who swiped one away doesn't get it back.
public enum RunActivityPlan {
    public static func actions(
        _ activities: [RunActivityRecord], _ snapshot: RunActivitySnapshot, now: Date, startFor: UUID? = nil
    ) -> [RunActivityAction] {
        var actions: [RunActivityAction] = []
        let later = RunActivityDismissal.after(now.addingTimeInterval(RunActivityContent.dismissSeconds))
        var live: [String: [RunActivityRecord]] = [:]
        for activity in activities where activity.phase.isLive {
            live[key(activity.attributes), default: []].append(activity)
        }
        var shown: Set<String> = []
        for key in live.keys.sorted() {
            let group = (live[key] ?? []).sorted(by: newer)
            guard let keep = group.first else { continue }
            for duplicate in group.dropFirst() { actions.append(.end(id: duplicate.id, duplicate.state, .immediate)) }
            guard let run = run(for: keep.attributes, showing: keep.state.runId, in: snapshot) else {
                actions.append(.end(id: keep.id, keep.state, .immediate))
                continue
            }
            let desired = RunActivitySnapshot.state(run)
            switch run.status {
            case .running, .paused:
                shown.insert(key)
                guard let desired, !desired.showsSame(as: keep.state), !isAhead(keep.state, of: run) else { continue }
                actions.append(.update(id: keep.id, desired))
            case .finishing, .stopped:
                actions.append(.end(id: keep.id, desired ?? ended(keep.state, run.status), later))
            case .discarded:
                actions.append(.end(id: keep.id, desired ?? ended(keep.state, run.status), .immediate))
            }
        }
        for activity in activities where activity.phase == .ended && activity.state.runStatus == .finishing {
            let run = run(for: activity.attributes, showing: activity.state.runId, in: snapshot)
            switch run?.status {
            case .finishing, .running, .paused:
                continue  // still waiting for its answers; or a new run, whose activity is another
            case .stopped:
                guard let run, run.answers(to: activity.state.runId), let desired = RunActivitySnapshot.state(run)
                else { continue }
                actions.append(.end(id: activity.id, desired, later))
            case .discarded, nil:
                actions.append(.end(id: activity.id, activity.state, .immediate))
            }
        }
        if let startFor, let run = snapshot.run(topicId: startFor), run.isOpen {
            let attributes = RunActivityContent.attributes(
                serverId: snapshot.serverId, topicId: startFor,
                topicName: snapshot.topicNames[startFor] ?? run.topic?.name ?? "")
            if !shown.contains(key(attributes)) {
                // A run whose steps aren't stored here is shown without them until they are.
                let state = RunActivitySnapshot.state(run) ?? RunActivitySnapshot.stateWithoutSteps(run)
                actions.append(.request(attributes, state))
            }
        }
        return actions
    }

    static func key(_ attributes: RunActivityAttributes) -> String {
        "\(attributes.serverId.lowercased())/\(attributes.topicId.lowercased())"
    }

    /// The view's run for an activity showing `runId`: none for another server's activity.
    static func run(for attributes: RunActivityAttributes, showing runId: String?, in snapshot: RunActivitySnapshot)
        -> LocalRun?
    {
        guard attributes.serverId.lowercased() == snapshot.serverId.lowercased(),
            let topicId = UUID(uuidString: attributes.topicId)
        else { return nil }
        return snapshot.run(topicId: topicId, showing: runId)
    }

    /// Most recently updated first.
    static func newer(_ a: RunActivityRecord, _ b: RunActivityRecord) -> Bool {
        let (sa, sb) = (a.staleDate ?? .distantPast, b.staleDate ?? .distantPast)
        if sa != sb { return sa > sb }
        if a.state.revision != b.state.revision { return a.state.revision > b.state.revision }
        return a.id < b.id
    }

    /// The activity shows a later server state of `run` than the view, which adds nothing to it.
    static func isAhead(_ state: RunActivityState, of run: LocalRun) -> Bool {
        guard run.queued.isEmpty, run.answers(to: state.runId) else { return false }
        return state.revision > (run.server?.revision ?? 0)
    }

    /// The activity's own state, with the run's final status: when the view can't build one.
    static func ended(_ state: RunActivityState, _ status: RunStatus) -> RunActivityState {
        var state = state
        state.status = status.rawValue
        if status == .discarded {
            state.endedAt = nil
            state.activeMs = nil
        }
        return state
    }
}
