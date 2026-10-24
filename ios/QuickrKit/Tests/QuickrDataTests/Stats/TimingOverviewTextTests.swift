import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The Overview's Timing section (timers.md §9, §11.2): complete runs only for best, median and
/// mean, "(all runs)" on the line, retired steps marked, an empty state for a timed topic.
@Suite struct TimingOverviewTextTests {
    static func decode(_ json: String) throws -> TopicTimingDTO {
        try WireCoding.decoder().decode(TopicTimingDTO.self, from: Data(json.utf8))
    }

    /// Three runs, two complete: best 4:00, median 4:30, mean 4:40 differ; a retired step.
    static let three = """
        {"runs": 3, "complete_runs": 2,
         "total": {"best_ms": 240000, "median_ms": 270000, "mean_ms": 280000},
         "steps": [
           {"key": "shower", "label": "Shower", "current": true, "done": 3, "skipped": 0,
            "best_ms": 120000, "median_ms": 150000, "mean_ms": 150000},
           {"key": "dress", "label": "Dress", "current": true, "done": 2, "skipped": 1,
            "best_ms": 60000, "median_ms": 75000, "mean_ms": 75000},
           {"key": "prep", "label": "Old prep", "current": false, "done": 1, "skipped": 0,
            "best_ms": 30000, "median_ms": 30000, "mean_ms": 30000}],
         "laps": {"runs_with_laps": 1, "median_ms": 15000, "mean_ms": 15000},
         "paused": {"runs_with_pauses": 0, "median_ms": null},
         "series": [
           {"entry_id": "0a000000-0000-4000-8000-000000000001", "captured_at": "2026-03-04T11:05:30Z",
            "started_at": "2026-03-04T11:00:00Z", "active_ms": 3725000, "paused_ms": 0, "complete": true, "steps": {}}]}
        """

    @Test func bestMedianAndMeanAreOverCompleteRuns() throws {
        let text = TimingOverviewText(try Self.decode(Self.three))
        #expect(text.best == "4:00")
        #expect(text.median == "4:30")
        #expect(text.mean == "4:40")
        #expect(text.completeNote == "Best, median and mean over complete runs: 2 of 3 runs")
        #expect(TimingOverviewText.lineTitle == "Run time (all runs)")
        let point = text.points.first?.activeMs
        #expect(point == 3_725_000)
        #expect(TimingOverviewText.duration(3_725_000) == "1:02:05", "h:mm:ss from an hour")
    }

    @Test func stepsShowMedianBestRetiredAndSkipped() throws {
        let text = TimingOverviewText(try Self.decode(Self.three))
        let labels = text.steps.map(\.label)
        #expect(labels == ["Shower", "Dress", "Old prep"])
        let retired = text.steps.map(\.retired)
        #expect(retired == [false, false, true])
        let dress = try #require(text.steps.dropFirst().first)
        #expect(dress.median == "1:15")
        #expect(dress.best == "1:00")
        #expect(dress.counts == "2 runs · skipped 1×")
        #expect(dress.share == 0.5)
        let shower = try #require(text.steps.first)
        #expect(shower.share == 1)
        #expect(shower.bestShare == 0.8)
        #expect(text.lapMedian == "0:15")
        #expect(text.pausedMedian == "—")
    }

    @Test func theFixtureDecodesAndShows() throws {
        let body = try #require(try Fixtures.api("getTopicTiming").body)
        let timing = try WireCoding.decoder().decode(TopicTimingDTO.self, from: body)
        guard case .stats(let text) = TimingOverviewText.shown(timing, timed: true) else {
            Issue.record("not shown")
            return
        }
        #expect(text.median == "5:00")
        #expect(text.runsWithPauses == "1")
    }

    @Test func noRunsIsEmptyForATimedTopicAndHiddenOtherwise() throws {
        let body = try #require(try Fixtures.api("getTopicTiming.untimed").body)
        let none = try WireCoding.decoder().decode(TopicTimingDTO.self, from: body)
        #expect(TimingOverviewText.shown(none, timed: true) == .empty)
        #expect(TimingOverviewText.shown(none, timed: false) == .hidden)
        #expect(TimingOverviewText.shown(nil, timed: false) == .hidden)
    }
}
