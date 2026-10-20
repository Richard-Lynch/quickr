import Foundation
import QuickrCore

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

    /// The entry dates for `topics` from `now`: sorted, distinct, `now` first, within `horizon`,
    /// at most `maxEntries` (due changes are kept before refresh points).
    public static func entryDates(for topics: [Topic], now: Date) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var changes = Set<Date>()
        for topic in topics {
            guard let schedule = topic.schedule else { continue }
            let points = Due.timeline(
                of: schedule, now: now, lastEntryAt: topic.lastCapturedAt,
                scheduleSince: topic.scheduleUpdatedAt ?? topic.createdAt, archived: topic.status == .archived,
                count: 24)
            for point in points.dropFirst() where point.date > now && point.date <= end { changes.insert(point.date) }
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
/// last entry and last quick answer, and its queued and failed counts; due state itself follows
/// from these and the clock, which the timelines already handle.
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
    }

    let topics: [Topic]

    public init(_ topics: [WidgetTopic]) {
        self.topics = topics.map {
            Topic(
                id: $0.topic.id, name: $0.topic.name, slug: $0.topic.slug, status: $0.topic.status,
                currentVersion: $0.topic.currentVersion, schedule: $0.topic.schedule,
                scheduleUpdatedAt: $0.topic.scheduleUpdatedAt, lastCapturedAt: $0.topic.lastCapturedAt,
                entryCount: $0.topic.entryCount, lastAnswer: $0.lastAnswer, queued: $0.queued, failed: $0.failed)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
