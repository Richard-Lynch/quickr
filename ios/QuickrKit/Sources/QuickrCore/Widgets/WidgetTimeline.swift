import Foundation

/// The widgets' reload policy (PLAN §2: reload only when due state or last values change, to stay
/// within WidgetKit's budget).
///
/// - **Inside a timeline** (free): an entry now, one at every instant a shown topic's due state
///   may change (`Due.timeline`), and refresh points so relative text ("5 min ago", "Due in
///   25 min") stays true: every 15 minutes for the first 2 hours, then hourly, up to `horizon`.
///   The timeline asks to be rebuilt after its last entry.
/// - **From the app** (`WidgetFingerprint`): a reload only when something a widget shows changed.
///   A log from a widget's own button reloads that widget anyway (WidgetKit does it after the
///   intent).
public enum WidgetTimeline {
    public static let horizon: TimeInterval = 12 * 60 * 60
    /// WidgetKit renders entries lazily, but a timeline still has to stay small.
    public static let maxEntries = 48

    /// The entry dates for `topics` from device time `now`: sorted, distinct, `now` first, within
    /// `horizon`, at most `maxEntries` (due changes are kept before refresh points). Due changes
    /// are the server's (at `now + skew`, sync-protocol.md §10), mapped back to device time,
    /// which is what WidgetKit schedules by.
    public static func entryDates(for topics: [Topic], now: Date, skew: TimeInterval) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var changes = Set<Date>()
        for topic in topics {
            guard let schedule = topic.schedule else { continue }
            let points = Due.timeline(
                of: schedule, now: ServerClock(skew: skew).now(at: now), lastEntryAt: topic.lastCapturedAt,
                scheduleSince: topic.scheduleUpdatedAt ?? topic.createdAt, archived: topic.status == .archived,
                count: 24)
            for point in points.dropFirst() {
                let date = point.date.addingTimeInterval(-skew)
                if date > now && date <= end { changes.insert(date) }
            }
        }
        var refreshes: [Date] = []
        var at = now
        while true {
            at = at.addingTimeInterval(at.timeIntervalSince(now) < 2 * 60 * 60 ? 15 * 60 : 60 * 60)
            guard at <= end else { break }
            refreshes.append(at)
        }
        let kept = Array(changes.sorted().prefix(maxEntries - 1))
        let room = maxEntries - 1 - kept.count
        let all = Set(kept).union(refreshes.prefix(max(0, room)))
        return [now] + all.sorted()
    }

    /// A timeline whose content changes at `changes` (each value from its date on; the first is
    /// the value at `dates[0]`): an entry at each of `dates` and each change, sorted and distinct,
    /// with the value current then; at most `maxEntries`.
    public static func entries<Value>(_ dates: [Date], changes: [(from: Date, value: Value)])
        -> [(date: Date, value: Value)]
    {
        guard let first = changes.first else { return [] }
        let all = Set(dates).union(changes.dropFirst().map(\.from)).sorted().prefix(maxEntries)
        return all.map { date in (date, changes.last { $0.from <= date }?.value ?? first.value) }
    }

    /// When WidgetKit should ask for the next timeline: after the last entry, or at `alert` (a
    /// pending alert the entries don't follow past, device time) when that comes first, so the
    /// alert line moves on to the next alert, or goes, instead of staying at 0:00.
    public static func reloadDate(after dates: [Date], now: Date, alert: Date? = nil) -> Date {
        let last = dates.last.map { max($0, now.addingTimeInterval(15 * 60)) } ?? now.addingTimeInterval(horizon)
        guard let alert, alert > now else { return last }
        return min(last, alert)
    }
}

/// What the widgets show, reduced to a value the app compares to decide whether to reload them
/// (`WidgetCenter.reloadAllTimelines`). Covers each active topic's identity, questions, schedule,
/// last entry and last quick answer, its queued and failed counts and the run it shows (its
/// content state, which changes with each tap, not as it ticks), and the store's skew; due
/// state itself follows from these and the clock, which the timelines already handle, as they
/// do the run's pending alert (`alert_at` moves on as each passes: not compared).
public struct WidgetFingerprint: Sendable, Hashable {
    struct Topic: Sendable, Hashable {
        var id: UUID
        var name: String
        var slug: String
        var status: TopicStatus
        var currentVersion: Int
        var schedule: Schedule?
        var scheduleUpdatedAt: Date?
        var lastCapturedAt: Date?
        var entryCount: Int
        var lastAnswer: AnswerValue?
        var queued: Int
        var failed: Int
        var scope: EntryScope?
        var run: RunActivityState?
        /// The one Auto chip's press (`WidgetTopic.runAuto`): the run's local state can change it
        /// while the activity state reads the same.
        var runAuto: WidgetRunButton?
        var updateRequired: Bool
    }

    let topics: [Topic]
    /// The skew to the minute: the smoothed estimate moves a little with every pull, which
    /// shouldn't spend reloads, but a clock that's off by minutes moves every due change.
    let skewMinutes: Int

    public init(_ topics: [WidgetTopic]) {
        skewMinutes = Int(((topics.first?.skew ?? 0) / 60).rounded())
        self.topics = topics.map {
            Topic(
                id: $0.topic.id, name: $0.topic.name, slug: $0.topic.slug, status: $0.topic.status,
                currentVersion: $0.topic.currentVersion, schedule: $0.topic.schedule,
                scheduleUpdatedAt: $0.topic.scheduleUpdatedAt, lastCapturedAt: $0.topic.lastCapturedAt,
                entryCount: $0.topic.entryCount, lastAnswer: $0.lastAnswer, queued: $0.queued, failed: $0.failed,
                scope: $0.scope, run: $0.run?.withoutAlert, runAuto: $0.runAuto, updateRequired: $0.updateRequired)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// What a topic's Control shows and does (`TopicControl`): its name, whether it logs and what
/// (questions version, last answer, the run a timer Control advances), and the store its action
/// is pinned to. Not "queued", the schedule or the run's pending alert: a Control doesn't show
/// them, so they don't spend its reloads.
public struct ControlFingerprint: Sendable, Hashable {
    struct Topic: Sendable, Hashable {
        var id: UUID
        var name: String
        var status: TopicStatus
        var currentVersion: Int
        var lastAnswer: AnswerValue?
        var scope: EntryScope?
        var run: RunActivityState?
        /// What the Control's one press does (`WidgetTopic.runAuto`), its detail and icon.
        var runAuto: WidgetRunButton?
    }

    let topics: [Topic]

    public init(_ topics: [WidgetTopic]) {
        self.topics = topics.map {
            Topic(
                id: $0.topic.id, name: $0.topic.name, status: $0.topic.status,
                currentVersion: $0.topic.currentVersion, lastAnswer: $0.lastAnswer, scope: $0.scope,
                run: $0.run?.withoutAlert, runAuto: $0.runAuto)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

extension RunActivityState {
    /// The state without its pending alert, which changes with time alone (the next after the
    /// instant it's read for), not with a tap.
    fileprivate var withoutAlert: RunActivityState {
        var state = self
        state.alertAt = nil
        state.alertLabel = nil
        return state
    }
}

/// The app's side of the reload policy: reload the widgets only when what they show changed
/// (the first state after launch, or after a server switch, always reloads).
public struct WidgetReloadGate<Fingerprint: Hashable & Sendable>: Sendable {
    private var last: Fingerprint?

    public init() {}

    /// Whether `fingerprint` differs from the last one seen (and remembers it).
    public mutating func shouldReload(_ fingerprint: Fingerprint) -> Bool {
        defer { last = fingerprint }
        return fingerprint != last
    }
}
