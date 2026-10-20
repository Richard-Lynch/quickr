import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The Overview's chart models and text against `shared/fixtures/stats-chart-vectors.json`, which
/// the PWA's own chart code made from the server's responses in `stats-vectors.json` (en-US).
@Suite struct StatsChartVectorTests {
    // MARK: - Fixtures

    struct Input: Decodable {
        struct Case: Decodable {
            var name: String
            var kind: String
            var topic: String
            var question: String?
            var query: [String: String]
            var response: JSONValue
        }

        var cases: [Case]
    }

    struct Charts: Decodable {
        struct Meta: Decodable {
            var locale: String
            var widths: [Double]
            var summaryTz: String

            enum CodingKeys: String, CodingKey {
                case locale, widths
                case summaryTz = "summary_tz"
            }
        }

        struct Labels: Decodable {
            var short: [String]
            var long: [String]
        }

        struct Series: Decodable {
            var name: String
            var tz: String
            var bucket: QuestionSeries.Bucket
            var type: String
            var chart: String
            var empty: Bool?
            var kept: [Int]?
            var ticks: [Double]?
            var tickLabels: [String]?
            var labelled: [String: [Int]]?
            var labels: Labels?
            var tooltips: [[String]]?
            var options: [String]?
            var max: Int?
            var totals: [Int]?
            var legend: [[String]]?
            var segments: [[[JSONValue]]]?

            enum CodingKeys: String, CodingKey {
                case name, tz, bucket, type, chart, empty, kept, ticks, labelled, labels, tooltips, options, max,
                    totals,
                    legend, segments
                case tickLabels = "tick_labels"
            }
        }

        struct Question: Decodable {
            var key: String
            var kind: String
            var label: String
            var answered: String
            var mean: String?
            var rows: [String]?
            var histogram: [String]?
            var histogramEnds: [String]?
            var visible: [String]?
            var top: [String]?
            var shares: [[String]]?
            var colors: [String]?
            var distinct: String?
            var mostCommon: [[JSONValue]]?
            var recent: [String]?

            enum CodingKeys: String, CodingKey {
                case key, kind, label, answered, mean, rows, histogram, visible, top, shares, colors, distinct, recent
                case histogramEnds = "histogram_ends"
                case mostCommon = "most_common"
            }
        }

        struct Stats: Decodable {
            var name: String
            var entries: String
            var first: String
            var sources: [[JSONValue]]
            var empty: Bool
            var questions: [Question]
        }

        struct Tick: Decodable {
            var min: Double
            var max: Double
            var ticks: [Double]
            var labels: [String]
        }

        struct Number: Decodable {
            var value: JSONValue
            var dec: Int
            var text: String
        }

        struct Percent: Decodable {
            var share: Double
            var text: String
        }

        struct Synthetic: Decodable {
            var name: String
            var chart: String
            var bucket: QuestionSeries.Bucket
            var points: [JSONValue]
            var empty: Bool?
            var kept: [Int]?
            var ticks: [Double]?
            var labelled: [String: [Int]]?
            var labels: Labels?
            var options: [[String]]?
            var max: Int?
            var legend: [[String]]?
            var segments: [[[JSONValue]]]?
        }

        struct Pick: Decodable {
            var xs: [Double]
            var gap: Double
            var labelled: [Int]
        }

        var meta: Meta
        var defaultBucket: [[String]]
        var ticks: [Tick]
        var numbers: [Number]
        var percents: [Percent]
        var pick: [Pick]
        var series: [Series]
        var synthetic: [Synthetic]
        var stats: [Stats]

        enum CodingKeys: String, CodingKey {
            case meta, ticks, numbers, percents, pick, series, synthetic, stats
            case defaultBucket = "default_bucket"
        }
    }

    static let input: Input = load("stats-vectors.json")
    static let charts: Charts = load("stats-chart-vectors.json")
    static let locale = Locale(identifier: "en_US")

    static func load<T: Decodable>(_ name: String) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Fixtures.data(name))
        } catch {
            fatalError("\(name): \(error)")
        }
    }

    static func response<T: WireResponse>(_ type: T.Type, _ name: String) throws -> T.Domain {
        let input = try #require(Self.input.cases.first { $0.name == name }, "no input case \(name)")
        let data = try JSONEncoder().encode(input.response)
        return try T.decode(data, using: WireCoding.decoder()).toDomain()
    }

    static func zone(_ identifier: String) throws -> TimeZone { try #require(TimeZone(identifier: identifier)) }

    // MARK: - Helpers alone

    @Test func theFixturesAreEnUSAndCoverEveryChart() {
        #expect(Self.charts.meta.locale == "en-US")
        #expect(Set(Self.charts.series.map(\.chart)) == ["line", "stacked", "none"])
        #expect(Self.charts.series.contains { $0.empty == true })
        #expect(Self.charts.series.count == Self.input.cases.filter { $0.kind == "series" }.count)
        #expect(Self.charts.stats.count == Self.input.cases.filter { $0.kind == "stats" }.count)
    }

    @Test func niceTicks() {
        for c in Self.charts.ticks {
            let ticks = ChartScale.niceTicks(min: c.min, max: c.max, count: 4)
            #expect(ticks == c.ticks, "niceTicks(\(c.min), \(c.max))")
            #expect(ticks.map { ChartFormat.tick($0, locale: Self.locale) } == c.labels, "formatTick \(c.ticks)")
        }
    }

    @Test func numbersAndPercents() {
        for c in Self.charts.numbers {
            let value: Double? =
                switch c.value {
                case .number(let n): n
                case .string("NaN"): .nan
                default: nil
                }
            #expect(ChartFormat.number(value, maxDecimals: c.dec, locale: Self.locale) == c.text, "\(c.value) \(c.dec)")
        }
        for c in Self.charts.percents {
            #expect(ChartFormat.percent(c.share) == c.text, "\(c.share)")
        }
    }

    @Test func pickLabels() {
        for c in Self.charts.pick {
            #expect(ChartScale.pickLabels(c.xs, minGap: c.gap).sorted() == c.labelled, "\(c.xs) gap \(c.gap)")
        }
    }

    @Test func defaultBuckets() {
        let days = ["7d": 7, "30d": 30, "90d": 90]
        for pair in Self.charts.defaultBucket {
            #expect(ChartDefaults.bucket(forRangeDays: days[pair[0]]).rawValue == pair[1], "\(pair[0])")
        }
    }

    // MARK: - Series

    @Test(arguments: charts.series.map(\.name)) func series(_ name: String) throws {
        let expected = try #require(Self.charts.series.first { $0.name == name })
        let series = try Self.response(QuestionSeriesDTO.self, name)
        #expect(series.bucket == expected.bucket)
        let zone = try Self.zone(expected.tz)
        let widths = Self.charts.meta.widths
        switch expected.chart {
        case "line":
            let models = widths.map { LineChartModel(series: series.points, width: $0) }
            if expected.empty == true {
                #expect(models.allSatisfy { $0 == nil })
                return
            }
            let model = try #require(models[0])
            #expect(model.kept == expected.kept)
            #expect(model.ticks == expected.ticks)
            #expect(model.ticks.map { ChartFormat.tick($0, locale: Self.locale) } == expected.tickLabels)
            for (index, width) in widths.enumerated() {
                #expect(models[index]?.labelled.sorted() == expected.labelled?[Self.key(width)], "width \(width)")
            }
            try expectLabels(model.points, series.bucket, zone, expected.labels)
            let tooltips = model.points.map { point in
                [
                    ChartFormat.number(point.mean, locale: Self.locale),
                    "\(ChartFormat.number(point.min, locale: Self.locale))–\(ChartFormat.number(point.max, locale: Self.locale)) · n=\(point.count)",
                ]
            }
            #expect(tooltips == expected.tooltips)
        case "stacked":
            let stats = try Self.topicStats(of: name)
            let options = try Self.options(series.key, in: stats)
            let models = widths.map { StackedBarsModel(series: series.points, options: options, width: $0) }
            if expected.empty == true {
                #expect(models.allSatisfy { $0 == nil })
                return
            }
            let model = try #require(models[0])
            #expect(options.map(\.value) == expected.options)
            #expect(model.kept == expected.kept)
            #expect(model.max == expected.max)
            #expect(model.points.map(StackedBarsModel.total) == expected.totals)
            #expect(model.legend.map { [$0.value, $0.label] } == expected.legend)
            let segments = model.points.map {
                model.segments($0).map { [JSONValue.string($0.value), .number(Double($0.count))] }
            }
            #expect(segments == expected.segments)
            for (index, width) in widths.enumerated() {
                #expect(models[index]?.labelled.sorted() == expected.labelled?[Self.key(width)], "width \(width)")
            }
            try expectLabels(model.points, series.bucket, zone, expected.labels)
        default:
            #expect(series.type == .str)
        }
    }

    private func expectLabels(
        _ points: [QuestionSeries.Point], _ bucket: QuestionSeries.Bucket, _ zone: TimeZone, _ expected: Charts.Labels?
    ) throws {
        let expected = try #require(expected)
        #expect(
            points.map { ChartFormat.bucket($0.start, bucket, style: .short, timeZone: zone, locale: Self.locale) }
                == expected.short)
        #expect(
            points.map { ChartFormat.bucket($0.start, bucket, style: .long, timeZone: zone, locale: Self.locale) }
                == expected.long)
    }

    /// The topic's unfiltered stats, which give a series its options (as on the page).
    static func topicStats(of seriesName: String) throws -> TopicStats {
        let input = try #require(Self.input.cases.first { $0.name == seriesName })
        let name = try #require(
            Self.input.cases.first { $0.kind == "stats" && $0.topic == input.topic && $0.query.isEmpty }?.name)
        return try response(TopicStatsDTO.self, name)
    }

    static func options(_ key: String, in stats: TopicStats) throws -> [EnumOption] {
        guard case .choice(let choice) = stats.questions.first(where: { $0.key == key }) else {
            Issue.record("\(key) is not an enum question")
            return []
        }
        return choice.options.map(\.option)
    }

    /// `JSON.stringify` of a width: 320, not 320.0.
    static func key(_ width: Double) -> String { String(Int(width)) }

    /// Shapes the server doesn't send today: buckets without a mean or without answers, and
    /// values no option has.
    @Test(arguments: charts.synthetic.map(\.name)) func synthetic(_ name: String) throws {
        let expected = try #require(Self.charts.synthetic.first { $0.name == name })
        let body = JSONValue.object([
            "key": .string("k"), "type": .string(expected.chart == "line" ? "double" : "enum"),
            "bucket": .string(expected.bucket.rawValue), "points": .array(expected.points),
        ])
        let series = try QuestionSeriesDTO.decode(JSONEncoder().encode(body), using: WireCoding.decoder()).toDomain()
        let widths = Self.charts.meta.widths
        let utc = try Self.zone("UTC")
        if expected.chart == "line" {
            let models = widths.map { LineChartModel(series: series.points, width: $0) }
            if expected.empty == true {
                #expect(models.allSatisfy { $0 == nil })
                return
            }
            let model = try #require(models[0])
            #expect(model.kept == expected.kept)
            #expect(model.ticks == expected.ticks)
            for (index, width) in widths.enumerated() {
                #expect(models[index]?.labelled.sorted() == expected.labelled?[Self.key(width)], "width \(width)")
            }
            try expectLabels(model.points, series.bucket, utc, expected.labels)
        } else {
            let options = (expected.options ?? []).map { EnumOption(value: $0[0], label: $0[1]) }
            let models = widths.map { StackedBarsModel(series: series.points, options: options, width: $0) }
            let model = try #require(models[0])
            #expect(model.kept == expected.kept)
            #expect(model.max == expected.max)
            #expect(model.legend.map { [$0.value, $0.label] } == expected.legend)
            let segments = model.points.map {
                model.segments($0).map { [JSONValue.string($0.value), .number(Double($0.count))] }
            }
            #expect(segments == expected.segments)
            for (index, width) in widths.enumerated() {
                #expect(models[index]?.labelled.sorted() == expected.labelled?[Self.key(width)], "width \(width)")
            }
        }
    }

    // MARK: - Stats

    @Test(arguments: charts.stats.map(\.name)) func stats(_ name: String) throws {
        let expected = try #require(Self.charts.stats.first { $0.name == name })
        let stats = try Self.response(TopicStatsDTO.self, name)
        let summaryZone = try Self.zone(Self.charts.meta.summaryTz)
        #expect(ChartFormat.count(stats.entryCount, locale: Self.locale) == expected.entries)
        #expect(
            stats.firstCapturedAt.map { ChartFormat.date($0, timeZone: summaryZone, locale: Self.locale) } ?? "—"
                == expected.first)
        #expect(
            stats.sources.prefix(4).map { [JSONValue.string($0.value), .number(Double($0.count))] } == expected.sources)
        #expect((stats.entryCount == 0) == expected.empty)
        #expect(stats.questions.map(\.key) == expected.questions.map(\.key))
        for (question, card) in zip(stats.questions, expected.questions) {
            switch question {
            case .numeric(let q):
                #expect(card.kind == "numeric")
                #expect(q.label == card.label && "\(q.count)/\(q.count + q.missing)" == card.answered)
                let dec = q.type == .int ? 1 : 2
                #expect(ChartFormat.number(q.mean, maxDecimals: dec, locale: Self.locale) == card.mean, "\(q.key) mean")
                let rows = [q.median, q.min, q.max, q.stddev, q.sum].map {
                    ChartFormat.number($0, maxDecimals: dec, locale: Self.locale)
                }
                #expect(rows == card.rows, "\(q.key) rows")
                let bins = q.histogram.map {
                    "\(ChartFormat.number($0.lower, locale: Self.locale))–\(ChartFormat.number($0.upper, locale: Self.locale)): \($0.count)"
                }
                #expect(bins == card.histogram, "\(q.key) histogram")
                let ends = q.histogram.first.flatMap { first in
                    q.histogram.last.map {
                        [
                            ChartFormat.tick(first.lower, locale: Self.locale),
                            ChartFormat.tick($0.upper, locale: Self.locale),
                        ]
                    }
                }
                #expect(ends == card.histogramEnds, "\(q.key) histogram ends")
            case .choice(let q):
                #expect(card.kind == "enum")
                #expect(q.label == card.label && "\(q.count)/\(q.count + q.missing)" == card.answered)
                let view = ChoiceView(q)
                #expect(view.visible.map(\.option.value) == card.visible, "\(q.key) visible")
                #expect(view.top.map { [$0.option.value, ChartFormat.percent($0.share)] } == card.top, "\(q.key) top")
                let shares = q.options.map {
                    [$0.option.value, ChartFormat.count($0.count, locale: Self.locale), ChartFormat.percent($0.share)]
                }
                #expect(shares == card.shares, "\(q.key) shares")
                let options = q.options.map(\.option)
                let colors = options.map { option in
                    ChoiceView.colorSlot(option.value, in: options).map { "var(--color-series-\($0 + 1))" }
                        ?? "var(--color-line-strong)"
                }
                #expect(colors == card.colors, "\(q.key) colours")
            case .text(let q):
                #expect(card.kind == "str")
                #expect(q.label == card.label && "\(q.count)/\(q.count + q.missing)" == card.answered)
                #expect(ChartFormat.plural(q.distinct, "distinct answer", locale: Self.locale) == card.distinct)
                let common =
                    q.top.contains { $0.count > 1 }
                    ? q.top.prefix(5).map { [JSONValue.string($0.value), .number(Double($0.count))] } : nil
                #expect(common == card.mostCommon, "\(q.key) most common")
                #expect(q.recent.prefix(5).map(\.entryId.wireString) == card.recent, "\(q.key) recent")
            }
        }
    }
}
