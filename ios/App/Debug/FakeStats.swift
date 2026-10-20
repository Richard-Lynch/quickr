#if DEBUG
import Foundation
import QuickrCore
import QuickrData

/// The fake server's stats and series (`GET /topics/{ref}/stats`, `.../questions/{key}/series`)
/// over a fixed set of entries placed relative to today, computed the way
/// `backend/app/services/stats.py` does: sample standard deviation, interpolated median, ten
/// histogram bins (one per integer for a small integer range), buckets truncated in `tz` with
/// weeks from Monday, buckets without answers left out. Filters: `captured_from` and `source`.
enum FakeStats {
    struct Entry: Sendable {
        var daysAgo: Int
        var hour: Int
        var source: String
        var choices: [String: String] = [:]
        var numbers: [String: Int] = [:]

        func has(_ key: String) -> Bool { choices[key] != nil || numbers[key] != nil }
    }

    /// Workout over six weeks, so the 7-day, 30-day and all-time ranges differ.
    static let workout: [Entry] = [
        Entry(daysAgo: 0, hour: 7, source: "ios", choices: ["type": "run"], numbers: ["duration": 32]),
        Entry(daysAgo: 1, hour: 18, source: "ios", choices: ["type": "yoga"], numbers: ["duration": 45]),
        Entry(daysAgo: 2, hour: 7, source: "web", choices: ["type": "run"], numbers: ["duration": 28]),
        Entry(daysAgo: 4, hour: 12, source: "ios", choices: ["type": "swim"], numbers: ["duration": 50]),
        Entry(daysAgo: 5, hour: 7, source: "ios", choices: ["type": "run"], numbers: ["duration": 35]),
        Entry(daysAgo: 9, hour: 19, source: "web", choices: ["type": "yoga"], numbers: ["duration": 60]),
        Entry(daysAgo: 12, hour: 7, source: "ios", choices: ["type": "run"], numbers: ["duration": 25]),
        Entry(daysAgo: 16, hour: 8, source: "ios", choices: ["type": "swim"], numbers: ["duration": 40]),
        Entry(daysAgo: 23, hour: 7, source: "mcp", choices: ["type": "run"], numbers: ["duration": 30]),
        Entry(daysAgo: 38, hour: 18, source: "ios", choices: ["type": "yoga"], numbers: ["duration": 55]),
    ]

    static let mood: [Entry] = [
        Entry(daysAgo: 0, hour: 9, source: "ios", choices: ["mood": "good"]),
        Entry(daysAgo: 1, hour: 9, source: "ios", choices: ["mood": "ok"]),
        Entry(daysAgo: 1, hour: 21, source: "web", choices: ["mood": "good"]),
        Entry(daysAgo: 3, hour: 9, source: "ios", choices: ["mood": "bad"]),
        Entry(daysAgo: 6, hour: 9, source: "ios", choices: ["mood": "good"]),
        Entry(daysAgo: 10, hour: 9, source: "ios", choices: ["mood": "ok"]),
    ]

    struct Question: Sendable {
        var key: String
        var label: String
        var type: String
        var options: [(value: String, label: String)] = []
    }

    static let questions: [UUID: [Question]] = [
        FakeServer.workoutId: [
            Question(
                key: "type", label: "Type", type: "enum",
                options: [("run", "Run"), ("yoga", "Yoga"), ("swim", "Swim")]),
            Question(key: "duration", label: "Duration", type: "int"),
        ],
        FakeServer.moodId: [
            Question(
                key: "mood", label: "Mood", type: "enum", options: [("good", "Good"), ("ok", "OK"), ("bad", "Bad")])
        ],
    ]

    static func topic(_ ref: String) -> (id: UUID, entries: [Entry])? {
        switch ref {
        case "workout", FakeServer.workoutId.wireString: (FakeServer.workoutId, workout)
        case "mood", FakeServer.moodId.wireString: (FakeServer.moodId, mood)
        default: nil
        }
    }

    /// Entries with their instants (today's local midnight minus `daysAgo`, plus `hour`), filtered.
    static func filtered(_ entries: [Entry], query: [String: String], now: Date) -> [(Date, Entry)] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let from = query["captured_from"].flatMap(WireDate.parse)
        return entries.compactMap { entry in
            guard let day = calendar.date(byAdding: .day, value: -entry.daysAgo, to: today),
                let at = calendar.date(byAdding: .hour, value: entry.hour, to: day)
            else { return nil }
            if let from, at < from { return nil }
            if let source = query["source"], entry.source != source { return nil }
            return (at, entry)
        }
        .sorted { $0.0 < $1.0 }
    }

    static func iso(_ date: Date) -> String { date.ISO8601Format() }

    // MARK: - Stats

    static func stats(ref: String, query: [String: String], now: Date = Date()) -> Data? {
        guard let (id, entries) = topic(ref) else { return nil }
        let rows = filtered(entries, query: query, now: now)
        var sources: [String: Int] = [:]
        for (_, entry) in rows { sources[entry.source, default: 0] += 1 }
        let body: [String: Any] = [
            "topic_id": id.wireString,
            "entry_count": rows.count,
            "first_captured_at": rows.first.map { iso($0.0) } ?? NSNull(),
            "last_captured_at": rows.last.map { iso($0.0) } ?? NSNull(),
            "sources": sources.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { ["value": $0.key, "count": $0.value] },
            "questions": (questions[id] ?? []).map { question($0, rows) },
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func question(_ q: Question, _ rows: [(Date, Entry)]) -> [String: Any] {
        let total = rows.count
        if q.type == "enum" {
            let values = rows.compactMap { $0.1.choices[q.key] }
            return [
                "key": q.key, "label": q.label, "type": "enum", "multiple": false, "count": values.count,
                "missing": total - values.count,
                "options": q.options.map { option in
                    let count = values.filter { $0 == option.value }.count
                    return [
                        "value": option.value, "label": option.label, "archived": false, "count": count,
                        "share": values.isEmpty ? 0.0 : Double(count) / Double(values.count),
                    ] as [String: Any]
                },
            ]
        }
        let values = rows.compactMap { $0.1.numbers[q.key].map(Double.init) }.sorted()
        let count = values.count
        let sum = values.reduce(0, +)
        let mean = count > 0 ? sum / Double(count) : nil
        let median: Double? =
            count == 0
            ? nil
            : count % 2 == 1 ? values[count / 2] : (values[count / 2 - 1] + values[count / 2]) / 2
        let stddev: Double? =
            count < 2
            ? nil : (values.map { pow($0 - (mean ?? 0), 2) }.reduce(0, +) / Double(count - 1)).squareRoot()
        return [
            "key": q.key, "label": q.label, "type": q.type, "count": count, "missing": total - count,
            "min": values.first ?? NSNull(), "max": values.last ?? NSNull(), "mean": mean ?? NSNull(),
            "median": median ?? NSNull(), "stddev": stddev ?? NSNull(), "sum": count > 0 ? sum : NSNull(),
            "histogram": histogram(values, integer: q.type == "int"),
        ]
    }

    static func histogram(_ values: [Double], integer: Bool) -> [[String: Any]] {
        guard let lo = values.first, let hi = values.last else { return [] }
        let edges: [(Double, Double)] =
            integer && hi - lo + 1 <= 10
            ? (0...Int(hi - lo)).map { (lo + Double($0) - 0.5, lo + Double($0) + 0.5) }
            : {
                let width = (hi - lo) / 10 == 0 ? 1 : (hi - lo) / 10
                return (0..<10).map { (lo + Double($0) * width, lo + Double($0 + 1) * width) }
            }()
        let span = edges[edges.count - 1].1 - edges[0].0
        var counts = Array(repeating: 0, count: edges.count)
        for value in values {
            counts[min(Int(((value - edges[0].0) / span * Double(edges.count)).rounded(.down)), edges.count - 1)] += 1
        }
        return edges.enumerated().map { ["lower": $1.0, "upper": $1.1, "count": counts[$0]] }
    }

    // MARK: - Series

    static func series(ref: String, key: String, query: [String: String], now: Date = Date()) -> Data? {
        guard let (id, entries) = topic(ref), let q = questions[id]?.first(where: { $0.key == key }) else { return nil }
        let bucket = query["bucket"] ?? "day"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = query["tz"].flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let component: Calendar.Component = bucket == "week" ? .weekOfYear : bucket == "month" ? .month : .day
        var groups: [Date: [Entry]] = [:]
        for (at, entry) in filtered(entries, query: query, now: now) where entry.has(key) {
            guard let start = calendar.dateInterval(of: component, for: at)?.start else { continue }
            groups[start, default: []].append(entry)
        }
        let points: [[String: Any]] = groups.keys.sorted().map { start in
            let group = groups[start] ?? []
            if q.type == "enum" {
                var counts: [String: Int] = [:]
                for entry in group { if let value = entry.choices[key] { counts[value, default: 0] += 1 } }
                return [
                    "start": iso(start), "count": group.count, "mean": NSNull(), "min": NSNull(), "max": NSNull(),
                    "option_counts": counts,
                ]
            }
            let values = group.compactMap { $0.numbers[key].map(Double.init) }
            return [
                "start": iso(start), "count": values.count, "mean": values.reduce(0, +) / Double(values.count),
                "min": values.min() ?? 0, "max": values.max() ?? 0, "option_counts": [String: Int](),
            ]
        }
        let body: [String: Any] = ["key": key, "type": q.type, "bucket": bucket, "points": points]
        return try? JSONSerialization.data(withJSONObject: body)
    }
}
#endif
