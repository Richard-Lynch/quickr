import Charts
import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The Overview's Timing section (timers.md §9, §11.2; the PWA's `TimingOverview`): best, median
/// and runs over complete runs, the run time of every run over time, each step's median bar with
/// its best marked and its skipped count, and laps and paused time. Hidden for an untimed topic
/// without runs; "No runs in this range" for a timed one.
struct TimingOverviewSection: View {
    let timing: OverviewModel.Load<TopicTimingDTO>
    /// The current version has a timer.
    let timed: Bool
    let bucket: QuestionSeries.Bucket

    var body: some View {
        switch timing {
        case .loading:
            if timed {
                RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius).fill(Color.qr.sunken).frame(height: 200)
                    .accessibilityElement()
                    .accessibilityLabel("Loading timing")
            }
        case .unavailable(let reason):
            if timed {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Could not load timing").font(.qr(.label))
                        Text(reason.message).font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("overview.timing.error")
            }
        case .loaded(let value, _):
            switch TimingOverviewText.shown(value, timed: timed) {
            case .hidden: EmptyView()
            case .empty:
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Run time").font(.qr(.section)).accessibilityAddTraits(.isHeader)
                        Text(TimingOverviewText.emptyText).font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("overview.timing.empty")
            case .stats(let text):
                TimingCards(text: text, bucket: bucket)
            }
        }
    }
}

private struct TimingCards: View {
    let text: TimingOverviewText
    let bucket: QuestionSeries.Bucket

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run time").font(.qr(.section)).accessibilityAddTraits(.isHeader)
                    Text(text.completeNote).font(.qr(.caption)).foregroundStyle(.qr.muted)
                        .accessibilityIdentifier("overview.timing.note")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text.median)
                        .font(.qr(.monoRegular, size: 34, relativeTo: .largeTitle).bold())
                    Text("median").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("overview.timing.median")
                HStack(spacing: 16) {
                    tile("Best", text.best, id: "best")
                    tile("Mean", text.mean, id: "mean")
                    tile("Runs", text.runs.formatted(), id: "runs")
                }
                let totals = text.totals(by: bucket, calendar: .autoupdatingCurrent)
                if !totals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TimingOverviewText.lineTitle(bucket)).font(.qr(.caption)).foregroundStyle(.qr.inkSoft)
                        RunTimeLine(points: totals, bucket: bucket)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.timing")
        if !text.steps.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Steps").font(.qr(.section)).accessibilityAddTraits(.isHeader)
                    ForEach(text.steps) { step in StepBar(step: step) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("overview.timing.steps")
        }
        Card {
            HStack(alignment: .top, spacing: 16) {
                tile("Runs with laps", text.runsWithLaps, id: "laps")
                tile("Lap time (median)", text.lapMedian, id: "lapMedian")
                tile("Runs with pauses", text.runsWithPauses, id: "pauses")
                tile("Paused (median)", text.pausedMedian, id: "pausedMedian")
            }
        }
    }

    private func tile(_ label: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.qr(.caption)).foregroundStyle(.qr.muted).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.qr(.mono)).bold().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview.timing.\(id)")
    }
}

/// A step's median as a bar, its best as a mark on it; retired steps flagged.
private struct StepBar: View {
    let step: TimingOverviewText.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.label).font(.qr(.label)).foregroundStyle(step.retired ? .qr.muted : .qr.ink).lineLimit(2)
                if step.retired { QuickrBadge("retired", tone: .warn) }
                Spacer(minLength: 8)
                Text("median \(step.median) · best \(step.best)").font(.qr(.monoCaption)).foregroundStyle(.qr.inkSoft)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.qr.sunken)
                    Capsule().fill(Color.qr.accent).frame(width: proxy.size.width * step.share)
                    Rectangle().fill(Color.qr.ink).frame(width: 2)
                        .offset(x: Swift.max(0, proxy.size.width * step.bestShare - 1))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            Text(step.counts).font(.qr(.caption)).foregroundStyle(.qr.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview.timing.step.\(step.key)")
    }
}

/// The average run per bucket (every run counted), over its min–max band, as the question
/// cards' `MeanLineChart` draws a mean.
private struct RunTimeLine: View {
    let points: [TimingOverviewText.BucketPoint]
    let bucket: QuestionSeries.Bucket

    var body: some View {
        Chart {
            ForEach(points, id: \.start) { point in
                if points.count > 1 {
                    AreaMark(
                        x: .value("Bucket", point.start), yStart: .value("Min", point.minMs),
                        yEnd: .value("Max", point.maxMs)
                    )
                    .foregroundStyle(Color.qr.accent.opacity(0.15))
                    .accessibilityHidden(true)
                    LineMark(x: .value("Bucket", point.start), y: .value("Average", point.meanMs))
                        .foregroundStyle(Color.qr.accent)
                        .accessibilityHidden(true)
                }
                PointMark(x: .value("Bucket", point.start), y: .value("Average", point.meanMs))
                    .foregroundStyle(Color.qr.accent)
                    .accessibilityLabel(ChartFormat.bucket(point.start, bucket))
                    .accessibilityValue(
                        "average \(DurationFormat.format(point.meanMs)), \(ChartFormat.plural(point.count, "run"))")
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.qr.line)
                AxisValueLabel {
                    if let ms = value.as(Int.self) { Text(DurationFormat.format(ms)).font(.qr(.monoCaption)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.start)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(ChartFormat.bucket(date, bucket)).font(.qr(.caption)) }
                }
            }
        }
        .frame(height: 160)
        .accessibilityLabel(TimingOverviewText.lineTitle(bucket))
        .accessibilityIdentifier("overview.timing.line")
    }
}
