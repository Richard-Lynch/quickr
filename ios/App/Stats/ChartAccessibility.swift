import Accessibility
import QuickrCore
import SwiftUI

/// VoiceOver's chart descriptions for the Overview's charts (a11y audit ST1): each bucket or bin
/// as a data point, so VoiceOver can step through them and play the chart as an Audio Graph,
/// instead of reading one long value.

/// A bucket as VoiceOver reads it, with its year: an "All" range can span years, and each data
/// point's category must be distinct ("Mar 29, 2025", "Week of Mar 29, 2025", "March 2025").
func spokenBucket(_ start: Date, _ bucket: QuestionSeries.Bucket) -> String {
    switch bucket {
    case .month: ChartFormat.bucket(start, .month, style: .long)
    case .week: "Week of \(ChartFormat.date(start))"
    case .day: ChartFormat.date(start)
    }
}

/// The mean per bucket (`MeanLineChart`), with each bucket's range and count as its label.
struct MeanLineDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let points: [QuestionSeries.Point]
    let bucket: QuestionSeries.Bucket
    let unit: String?
    let domain: ClosedRange<Double>

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = unit.map { " \($0)" } ?? ""
        let labels = points.map { spokenBucket($0.start, bucket) }
        let values = points.compactMap(\.mean)
        return AXChartDescriptor(
            title: title,
            summary: summary(values, unit: unit),
            xAxis: AXCategoricalDataAxisDescriptor(title: bucket.rawValue.capitalized, categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Average", range: domain, gridlinePositions: []) {
                ChartFormat.number($0) + unit
            },
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Average", isContinuous: true,
                    dataPoints: zip(labels, points).map { label, point in
                        AXDataPoint(
                            x: label, y: point.mean ?? 0, additionalValues: [],
                            label: "\(ChartFormat.number(point.min))–\(ChartFormat.number(point.max))\(unit), "
                                + ChartFormat.plural(point.count, "answer"))
                    })
            ])
    }

    private func summary(_ values: [Double], unit: String) -> String {
        guard let low = values.min(), let high = values.max() else { return "No answers" }
        let buckets = ChartFormat.plural(points.count, bucket.rawValue)
        return "\(buckets), averages from \(ChartFormat.number(low)) to \(ChartFormat.number(high))\(unit)"
    }
}

/// Answers per option per bucket (`OptionStackChart`): one series per option.
struct OptionStackDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let model: StackedBarsModel
    let bucket: QuestionSeries.Bucket

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = model.points.map { spokenBucket($0.start, bucket) }
        return AXChartDescriptor(
            title: title,
            summary: "\(ChartFormat.plural(model.points.count, bucket.rawValue)), "
                + ChartFormat.plural(model.legend.count, "option"),
            xAxis: AXCategoricalDataAxisDescriptor(title: bucket.rawValue.capitalized, categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Answers", range: 0...Double(model.max), gridlinePositions: []) {
                ChartFormat.count(Int($0))
            },
            additionalAxes: [],
            series: model.legend.map { item in
                AXDataSeriesDescriptor(
                    name: item.label, isContinuous: false,
                    dataPoints: zip(labels, model.points).map { label, point in
                        AXDataPoint(x: label, y: Double(point.optionCounts[item.value] ?? 0))
                    })
            })
    }
}

/// The distribution (`DistributionChart`): one data point per bin.
struct DistributionDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let bins: [QuestionStats.HistogramBin]
    let unit: String?

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = Self.categories(bins, unit: unit)
        let highest = Double(bins.map(\.count).max() ?? 0)
        return AXChartDescriptor(
            title: title,
            summary: ChartFormat.plural(bins.reduce(0) { $0 + $1.count }, "answer") + " in "
                + ChartFormat.plural(bins.count, "range"),
            xAxis: AXCategoricalDataAxisDescriptor(title: "Range", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(
                title: "Answers", range: 0...max(1, highest), gridlinePositions: []
            ) { ChartFormat.count(Int($0)) },
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Answers", isContinuous: false,
                    dataPoints: zip(labels, bins).map { AXDataPoint(x: $0, y: Double($1.count)) })
            ])
    }

    /// "2–4 h": a bin's range, with enough decimals to tell narrow bins apart.
    static func label(_ bin: QuestionStats.HistogramBin, unit: String?) -> String {
        "\(ChartFormat.number(bin.lower, maxDecimals: 4))–\(ChartFormat.number(bin.upper, maxDecimals: 4))"
            + (unit.map { " \($0)" } ?? "")
    }

    /// Each bin's label, numbered where two would still read the same (a category must be unique).
    static func categories(_ bins: [QuestionStats.HistogramBin], unit: String?) -> [String] {
        let labels = bins.map { label($0, unit: unit) }
        return labels.enumerated().map { index, label in
            labels.filter { $0 == label }.count > 1 ? "\(label) (bin \(index + 1))" : label
        }
    }
}
