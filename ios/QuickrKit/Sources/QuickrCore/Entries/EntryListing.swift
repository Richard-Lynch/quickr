import Foundation

/// The entries page's date range (the PWA's `lib/filters.ts`): the last 7, 30 or 90 local days,
/// or all time. The raw values are the URL's `range` values.
public enum EntryRange: String, Sendable, Hashable, CaseIterable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case all

    /// The PWA's default, also for an unknown value.
    public static let `default` = EntryRange.thirtyDays

    public init(parsing raw: String?) { self = raw.flatMap(EntryRange.init(rawValue:)) ?? .default }

    public var label: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .all: "All"
        }
    }

    var days: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .all: nil
        }
    }

    /// The first instant in range (the PWA's `captured_from`): local midnight today, minus
    /// `days - 1` days, so "7 days" is today and the 6 before. Nil for all time.
    ///
    /// Like the PWA's `setHours(0)` then `setDate`: on a day whose midnight a DST gap skips,
    /// "midnight" is the day's first instant (01:00), and going back keeps that wall time; a
    /// time a gap skips on the day it lands moves forward too.
    public func start(now: Date, calendar: Calendar) -> Date? {
        guard let days else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }
}

/// The entries page's filters (`range`, `version`, `source`); all three apply on the device.
public struct EntryListFilters: Sendable, Hashable {
    public var range: EntryRange
    public var version: Int?
    public var source: String?

    public init(range: EntryRange = .default, version: Int? = nil, source: String? = nil) {
        self.range = range
        self.version = version
        self.source = source
    }

    /// Anything but the defaults: the empty state reads "No entries match".
    public var isFiltered: Bool { range != .default || version != nil || source != nil }
}

/// A topic's entries as the server's `GET /topics/{ref}/entries` lists them (`list_entries` and
/// `apply_filters` in `backend/app/services/entries.py`), computed on the device; the source
/// choices like `topic_stats`; the answer columns like the PWA's `columnsFor`. Checked against
/// `shared/fixtures/entries-vectors.json` and `entries-range-vectors.json`.
public enum EntryListing {
    /// `captured_from` (inclusive), `version` and `source`, then `ORDER BY captured_at DESC, id`.
    public static func list<Value>(
        _ values: [Value], entry: (Value) -> Entry, capturedFrom: Date?, version: Int?, source: String?
    ) -> [Value] {
        values.filter { value in
            let e = entry(value)
            if let capturedFrom, e.capturedAt < capturedFrom { return false }
            if let version, e.version != version { return false }
            if let source, e.source != source { return false }
            return true
        }
        .sorted { a, b in
            let (x, y) = (entry(a), entry(b))
            if x.capturedAt != y.capturedAt { return x.capturedAt > y.capturedAt }
            // Ties by id ascending: Postgres compares UUIDs bytewise, like their lowercase text.
            return x.id.uuidString.lowercased() < y.id.uuidString.lowercased()
        }
    }

    /// The source filter's choices (`topic_stats` sources: most entries first). Equal counts, which
    /// the server leaves in no particular order, go alphabetically.
    public static func sources(_ entries: [Entry]) -> [(value: String, count: Int)] {
        Dictionary(grouping: entries, by: \.source)
            .map { (value: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    /// The answer columns (the PWA's `columnsFor`): the current questions in order, then keys only
    /// older versions have, each with its newest definition. `versions` in any order.
    public static func columns(current: [Question], versions: [TopicVersion]) -> [Question] {
        var seen = Set(current.map(\.key))
        var columns = current
        for version in versions.sorted(by: { $0.version > $1.version }) {
            for question in version.questions where !seen.contains(question.key) {
                seen.insert(question.key)
                columns.append(question)
            }
        }
        return columns
    }
}
