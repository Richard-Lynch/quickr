import Foundation

/// The home screen's sort options, in the PWA's order (`TopicsPage` `SORTS`). The raw values are
/// the API's `sort` values.
public enum TopicSort: String, Sendable, Hashable, CaseIterable {
    case due
    case recentActivity = "-activity"
    case recentlyEdited = "-updated"
    case nameAscending = "name"
    case nameDescending = "-name"
    case newest = "-created"
    case oldest = "created"

    public var label: String {
        switch self {
        case .due: "Due first"
        case .recentActivity: "Recent activity"
        case .recentlyEdited: "Recently edited"
        case .nameAscending: "Name A–Z"
        case .nameDescending: "Name Z–A"
        case .newest: "Newest"
        case .oldest: "Oldest"
        }
    }
}

/// The home screen's status filter (`TopicsPage` `STATUS`).
public enum TopicStatusFilter: String, Sendable, Hashable, CaseIterable {
    case active
    case archived
    case all

    public var label: String {
        switch self {
        case .active: "Active"
        case .archived: "Archived"
        case .all: "All"
        }
    }
}

/// The topic list the server's `GET /topics` returns (`list_topics` in
/// `backend/app/services/topics.py`), computed on the device from the local store: the status
/// filter, the search and every sort, with due status from `Due` at `now`. The PWA's sections
/// (`splitByDue`) and the due count (`dueCount`) are here too. Checked against `shared/fixtures/home-vectors.json`
/// (the real `list_topics`) and `home-due-vectors.json` (the PWA's sections).
public enum TopicListing {
    /// One listed topic with its due status at the listing's `now`.
    public struct Item<Value> {
        public var value: Value
        public var topic: Topic
        public var due: DueStatus?

        public init(value: Value, topic: Topic, due: DueStatus?) {
            self.value = value
            self.topic = topic
            self.due = due
        }
    }

    /// The server's `_due`: nil for an unscheduled topic; archived topics are never due.
    public static func due(of topic: Topic, at now: Date) -> DueStatus? {
        guard let schedule = topic.schedule else { return nil }
        return Due.status(
            of: schedule, now: now, lastEntryAt: topic.lastCapturedAt,
            scheduleSince: topic.scheduleUpdatedAt ?? topic.createdAt, archived: topic.status == .archived)
    }

    /// `list_topics(status:sort:q:)` over `values`, every page at once.
    public static func list<Value>(
        _ values: [Value], topic: (Value) -> Topic, now: Date, status: TopicStatusFilter, sort: TopicSort,
        query: String
    ) -> [Item<Value>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = values.compactMap { value -> Item<Value>? in
            let topic = topic(value)
            guard includes(topic, status: status), matches(topic, query: needle) else { return nil }
            return Item(value: value, topic: topic, due: due(of: topic, at: now))
        }
        return sorted(items, by: sort)
    }

    public static func includes(_ topic: Topic, status: TopicStatusFilter) -> Bool {
        switch status {
        case .active: topic.status == .active
        case .archived: topic.status == .archived
        case .all: true
        }
    }

    /// The server's search: one case-insensitive substring of the name, slug or description, or of
    /// a current question's key, label or help text. No accent folding (Postgres `ILIKE`); an
    /// empty query matches everything.
    public static func matches(_ topic: Topic, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        func hit(_ text: String?) -> Bool { text?.lowercased().contains(needle) ?? false }
        if hit(topic.name) || hit(topic.slug) || hit(topic.description) { return true }
        return topic.questions.contains { hit($0.key) || hit($0.label) || hit($0.helpText) }
    }

    /// The server's orderings. Every sort ends on the id (ascending, as Postgres and `str(uuid)`
    /// compare them), so equal keys have one order.
    public static func sorted<Value>(_ items: [Item<Value>], by sort: TopicSort) -> [Item<Value>] {
        switch sort {
        case .due:
            return items.sorted { dueKey($0) < dueKey($1) }
        case .recentActivity:
            return items.sorted { order(activity($0.topic), activity($1.topic), descending: true, $0, $1) }
        case .recentlyEdited:
            return items.sorted { order($0.topic.updatedAt, $1.topic.updatedAt, descending: true, $0, $1) }
        case .newest:
            return items.sorted { order($0.topic.createdAt, $1.topic.createdAt, descending: true, $0, $1) }
        case .oldest:
            return items.sorted { order($0.topic.createdAt, $1.topic.createdAt, descending: false, $0, $1) }
        case .nameAscending, .nameDescending:
            return items.sorted { a, b in
                switch nameOrder(a.topic.name, b.topic.name) {
                case .orderedSame: idString(a) < idString(b)
                case .orderedAscending: sort == .nameAscending
                case .orderedDescending: sort == .nameDescending
                }
            }
        }
    }

    /// `ORDER BY lower(name)`. The server's Postgres (`postgres:18-alpine`, musl) compares bytes
    /// whatever `datcollate` says: lowercase, then UTF-8 byte order, without normalising. So
    /// "a b" < "a-c" < "a.b" < "ab", "zed" < "éclair", and an NFD "é" sorts among the e's. The
    /// lowercasing is Swift's (full Unicode); musl's `towlower` can differ for rare characters.
    static func nameOrder(_ a: String, _ b: String) -> ComparisonResult {
        let x = Array(a.lowercased().utf8)
        let y = Array(b.lowercased().utf8)
        if x == y { return .orderedSame }
        return x.lexicographicallyPrecedes(y) ? .orderedAscending : .orderedDescending
    }

    /// The server's `_due_sort_key`: due topics (longest due first), then scheduled ones by their
    /// next slot (none: last), then unscheduled ones by recent activity.
    static func dueKey<Value>(_ item: Item<Value>) -> DueKey {
        if let due = item.due, due.isDue, let since = due.dueSince {
            return DueKey(group: 0, time: since.timeIntervalSince1970, id: idString(item))
        }
        if let due = item.due {
            return DueKey(group: 1, time: due.nextDueAt?.timeIntervalSince1970 ?? .infinity, id: idString(item))
        }
        return DueKey(group: 2, time: -activity(item.topic).timeIntervalSince1970, id: idString(item))
    }

    struct DueKey: Comparable {
        var group: Int
        var time: Double
        var id: String

        static func < (a: DueKey, b: DueKey) -> Bool {
            (a.group, a.time, a.id) < (b.group, b.time, b.id)
        }
    }

    /// `coalesce(last_captured_at, updated_at)`.
    static func activity(_ topic: Topic) -> Date { topic.lastCapturedAt ?? topic.updatedAt }

    /// `str(uuid)`: lowercase, which sorts like Postgres's byte order.
    static func idString<Value>(_ item: Item<Value>) -> String { item.topic.id.uuidString.lowercased() }

    private static func order<Value>(
        _ a: Date, _ b: Date, descending: Bool, _ x: Item<Value>, _ y: Item<Value>
    ) -> Bool {
        if a != b { return descending ? a > b : a < b }
        return idString(x) < idString(y)
    }

    // MARK: - The PWA's sections and the due count

    /// Ids of the topics with an open run (running or paused). A finishing run isn't open: its
    /// topic keeps its due state (timers.md §11.1).
    public typealias OpenRunTopics = Set<UUID>

    /// For callers that have no run data yet.
    public static let noOpenRuns: OpenRunTopics = []

    /// Whether a topic counts as due (the PWA's `countsAsDue`): active, due now, and without an
    /// open run (a timed topic with an open run shows "Running" instead of its due state, §11.1).
    public static func countsAsDue<Value>(_ item: Item<Value>, now: Date, openRuns: OpenRunTopics) -> Bool {
        item.topic.status == .active && !openRuns.contains(item.topic.id) && DueView.isDueNow(item.due, now: now)
    }

    /// The number of due topics (the PWA's `dueCount`): the one count behind the app badge, the
    /// NSE badge, the home screen's "Due now" and the widgets (timers.md §11.1), whatever the
    /// search or filter.
    public static func dueCount<Value>(_ items: [Item<Value>], now: Date, openRuns: OpenRunTopics) -> Int {
        items.count { countsAsDue($0, now: now, openRuns: openRuns) }
    }

    /// `dueCount` over topics, with each one's due status at `now`.
    public static func dueCount(_ topics: [Topic], now: Date, openRuns: OpenRunTopics) -> Int {
        dueCount(topics.map { Item(value: (), topic: $0, due: due(of: $0, at: now)) }, now: now, openRuns: openRuns)
    }

    /// The home screen's sections (the PWA's `splitByDue`): "Due now" (`countsAsDue`), "Coming
    /// up" (active and scheduled, by next slot, none last, stable) and the rest. "Due now" and the
    /// rest keep the list's order.
    public struct Sections<Value> {
        public var due: [Value] = []
        public var upcoming: [Value] = []
        public var other: [Value] = []

        public init(due: [Value] = [], upcoming: [Value] = [], other: [Value] = []) {
            self.due = due
            self.upcoming = upcoming
            self.other = other
        }
    }

    public static func sections<Value>(_ items: [Item<Value>], now: Date, openRuns: OpenRunTopics)
        -> Sections<Item<Value>>
    {
        var out = Sections<Item<Value>>()
        var upcoming: [(offset: Int, element: Item<Value>)] = []
        for item in items {
            if countsAsDue(item, now: now, openRuns: openRuns) {
                out.due.append(item)
            } else if item.topic.status == .active && item.topic.schedule != nil {
                upcoming.append((upcoming.count, item))
            } else {
                out.other.append(item)
            }
        }
        let never = Date(timeIntervalSince1970: 253_402_214_400)  // 9999-12-31, the PWA's stand-in
        out.upcoming = upcoming.sorted { a, b in
            let x = a.element.due?.nextDueAt ?? never
            let y = b.element.due?.nextDueAt ?? never
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        return out
    }

    /// The sections show only for the default view: due first, active, no search.
    public static func isSectioned(status: TopicStatusFilter, sort: TopicSort, query: String) -> Bool {
        sort == .due && status == .active && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
