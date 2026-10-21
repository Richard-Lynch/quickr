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

    /// When WidgetKit should ask for the next timeline: after the last entry.
    public static func reloadDate(after dates: [Date], now: Date) -> Date {
        dates.last.map { max($0, now.addingTimeInterval(15 * 60)) } ?? now.addingTimeInterval(horizon)
    }
}

/// What the widgets show, reduced to a value the app compares to decide whether to reload them
/// (`WidgetCenter.reloadAllTimelines`). Covers each active topic's identity, questions, schedule,
/// last entry and last quick answer, and its queued and failed counts, and the store's skew; due
/// state itself follows from these and the clock, which the timelines already handle.
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
                scope: $0.scope)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// What a topic's Control shows and does (`TopicControl`): its name, whether it logs and what
/// (questions version, last answer), and the store its action is pinned to. Not "queued" or the
/// schedule: a Control doesn't show them, so they don't spend its reloads.
public struct ControlFingerprint: Sendable, Hashable {
    struct Topic: Sendable, Hashable {
        var id: UUID
        var name: String
        var status: TopicStatus
        var currentVersion: Int
        var lastAnswer: AnswerValue?
        var scope: EntryScope?
    }

    let topics: [Topic]

    public init(_ topics: [WidgetTopic]) {
        self.topics = topics.map {
            Topic(
                id: $0.topic.id, name: $0.topic.name, status: $0.topic.status,
                currentVersion: $0.topic.currentVersion, lastAnswer: $0.lastAnswer, scope: $0.scope)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
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
