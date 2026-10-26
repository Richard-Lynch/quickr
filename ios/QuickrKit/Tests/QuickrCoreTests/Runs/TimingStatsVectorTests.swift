import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// R1 (timers.md §13.3): Swift/Python parity for the timing stats models. Every case in
/// shared/fixtures/timing-stats-vectors.json (generated from backend/app/services/timing_stats.py
/// by `make vectors`) gives the same answer here. One test walks every case.
@Suite struct TimingStatsVectorTests {
    struct Summary: Codable, Equatable {
        var bestMs: Int?
        var medianMs: Int?
        var meanMs: Int?

        enum CodingKeys: String, CodingKey {
            case bestMs = "best_ms"
            case medianMs = "median_ms"
            case meanMs = "mean_ms"
        }
    }

    struct Step: Codable, Equatable {
        var key: String
        var label: String
        var current: Bool
        var done: Int
        var skipped: Int
        var bestMs: Int?
        var medianMs: Int?
        var meanMs: Int?

        enum CodingKeys: String, CodingKey {
            case key, label, current, done, skipped
            case bestMs = "best_ms"
            case medianMs = "median_ms"
            case meanMs = "mean_ms"
        }
    }

    struct Laps: Codable, Equatable {
        var runsWithLaps: Int
        var medianMs: Int?
        var meanMs: Int?

        enum CodingKeys: String, CodingKey {
            case runsWithLaps = "runs_with_laps"
            case medianMs = "median_ms"
            case meanMs = "mean_ms"
        }
    }

    struct Paused: Codable, Equatable {
        var runsWithPauses: Int
        var medianMs: Int?

        enum CodingKeys: String, CodingKey {
            case runsWithPauses = "runs_with_pauses"
            case medianMs = "median_ms"
        }
    }

    struct Point: Codable, Equatable {
        var entryId: String
        var capturedAt: String
        var startedAt: String
        var activeMs: Int
        var pausedMs: Int
        var complete: Bool
        var steps: [String: Int]

        enum CodingKeys: String, CodingKey {
            case complete, steps
            case entryId = "entry_id"
            case capturedAt = "captured_at"
            case startedAt = "started_at"
            case activeMs = "active_ms"
            case pausedMs = "paused_ms"
        }
    }

    /// `TopicTiming` in the vectors' shape.
    struct Topic: Codable, Equatable {
        var runs: Int
        var completeRuns: Int
        var total: Summary
        var steps: [Step]
        var laps: Laps
        var paused: Paused
        var series: [Point]

        enum CodingKeys: String, CodingKey {
            case runs, total, steps, laps, paused, series
            case completeRuns = "complete_runs"
        }

        init(_ t: TimingStats.TopicTiming) {
            runs = t.runs
            completeRuns = t.completeRuns
            total = Summary(bestMs: t.total.bestMs, medianMs: t.total.medianMs, meanMs: t.total.meanMs)
            steps = t.steps.map {
                Step(
                    key: $0.key, label: $0.label, current: $0.current, done: $0.done, skipped: $0.skipped,
                    bestMs: $0.bestMs, medianMs: $0.medianMs, meanMs: $0.meanMs)
            }
            laps = Laps(runsWithLaps: t.laps.runsWithLaps, medianMs: t.laps.medianMs, meanMs: t.laps.meanMs)
            paused = Paused(runsWithPauses: t.paused.runsWithPauses, medianMs: t.paused.medianMs)
            series = t.series.map {
                Point(
                    entryId: $0.entryId, capturedAt: RunInstant.format($0.capturedAt),
                    startedAt: RunInstant.format($0.startedAt), activeMs: $0.activeMs, pausedMs: $0.pausedMs,
                    complete: $0.complete, steps: $0.steps)
            }
        }
    }

    struct Case: Decodable {
        struct Entry: Decodable {
            var entryId: String
            var capturedAt: String
            var timing: RunWire.WireTiming?

            enum CodingKeys: String, CodingKey {
                case timing
                case entryId = "entry_id"
                case capturedAt = "captured_at"
            }
        }

        var name: String
        var versions: [String: [RunWire.Step]?]
        var currentVersion: Int
        var entries: [Entry]
        var expected: Topic

        enum CodingKeys: String, CodingKey {
            case name, versions, entries, expected
            case currentVersion = "current_version"
        }
    }

    static func load() throws -> [Case] {
        struct File: Decodable { var cases: [Case] }
        return try JSONDecoder().decode(File.self, from: Fixtures.data("timing-stats-vectors.json")).cases
    }

    @Test func casesHaveUniqueNames() throws {
        let cases = try Self.load()
        #expect(cases.count >= 15)
        #expect(Set(cases.map(\.name)).count == cases.count)
    }

    @Test func everyCaseMatchesTheReference() throws {
        let cases = try Self.load()
        var ran: [String] = []
        for c in cases {
            var versions: [Int: [TopicTimer.Step]?] = [:]
            for (number, steps) in c.versions {
                versions.updateValue(
                    steps.map { $0.map(\.domain) }, forKey: try #require(Int(number), "\(c.name): version \(number)"))
            }
            let entries = try c.entries.map { e in
                TimingStats.TimedEntry(
                    entryId: e.entryId, capturedAt: try RunWire.instant(e.capturedAt), timing: try e.timing?.domain())
            }
            let stats = TimingStats.compute(entries, versions: versions, currentVersion: c.currentVersion)
            #expect(Topic(stats) == c.expected, "\(c.name)")
            ran.append(c.name)
        }
        #expect(ran == cases.map(\.name), "every case ran")
    }

    @Test func medianAndMeanFloor() {
        #expect(TimingStats.median([]) == nil)
        #expect(TimingStats.median([3, 1, 2]) == 2)
        #expect(TimingStats.median([1, 2]) == 1)
        #expect(TimingStats.median([4, 1, 3, 2]) == 2)
        #expect(TimingStats.mean([1, 2]) == 1)
        #expect(TimingStats.mean([]) == nil)
    }
}
