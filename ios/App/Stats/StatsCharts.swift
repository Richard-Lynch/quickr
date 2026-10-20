import Charts
import QuickrCore
import QuickrUI
import SwiftUI

/// The Overview's charts (the PWA's `components/charts`), drawn with Swift Charts from the
/// QuickrCore models: the same kept buckets, value ticks, labelled buckets, legend and colours.

/// An option's colour: its slot among the question's first six options, else the "other" colour.
func optionColor(_ value: String, in options: [EnumOption]) -> Color {
    ChoiceView.colorSlot(value, in: options).map { Color.qr.series($0 + 1) } ?? .qr.lineStrong
}

/// "No answers in this range." in a chart's place.
struct NoAnswers: View {
    var body: some View {
        Text("No answers in this range.")
            .font(.qr(.subheadline))
            .foregroundStyle(.qr.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }
}

// MARK: - Line (int, double)

/// The mean per bucket as a line over a soft min–max band, with a tap-and-drag tooltip
/// (`LineChart`).
struct MeanLineChart: View {
    let series: QuestionSeries
    let unit: String?
    let label: String
    @State private var selected: Date?

    var body: some View {
        GeometryReader { proxy in
            if let model = LineChartModel(series: series.points, width: proxy.size.width) {
                chart(model)
            } else {
                NoAnswers()
            }
        }
        .frame(height: LineChartModel.height)
    }

    private func chart(_ model: LineChartModel) -> some View {
        let labelled = Set(model.labelled.map { model.points[$0].start })
        let shown = selected.flatMap { date in
            model.points.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
        }
        return Chart {
            ForEach(model.points, id: \.start) { point in
                if model.points.count > 1 {
                    AreaMark(
                        x: .value("Bucket", point.start),
                        yStart: .value("Min", point.min ?? point.mean ?? 0),
                        yEnd: .value("Max", point.max ?? point.mean ?? 0)
                    )
                    .foregroundStyle(Color.qr.accent.opacity(0.15))
                    LineMark(x: .value("Bucket", point.start), y: .value("Mean", point.mean ?? 0))
                        .foregroundStyle(Color.qr.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if model.points.count <= 40 {
                    PointMark(x: .value("Bucket", point.start), y: .value("Mean", point.mean ?? 0))
                        .foregroundStyle(Color.qr.accent)
                        .symbolSize(shown?.start == point.start ? 100 : 50)
                }
            }
            if let shown {
                RuleMark(x: .value("Bucket", shown.start)).foregroundStyle(Color.qr.ink.opacity(0.4))
            }
        }
        .chartYScale(domain: model.domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: model.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.qr.line)
                AxisValueLabel {
                    if let tick = value.as(Double.self) { Text(ChartFormat.tick(tick)).font(.qr(.monoCaption)) }
                }
            }
        }
        .chartXScale(domain: xDomain(model))
        .chartXAxis {
            AxisMarks(values: model.points.map(\.start).filter { labelled.contains($0) }) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(ChartFormat.bucket(date, series.bucket)).font(.qr(.caption))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartOverlay { _ in
            if let shown { tooltip(shown) }
        }
        .accessibilityLabel("\(label): average per \(series.bucket.rawValue)")
        .accessibilityValue(accessibilitySummary(model))
    }

    /// One bucket is centred, as the PWA draws it.
    private func xDomain(_ model: LineChartModel) -> ClosedRange<Date> {
        let first = model.points[0].start
        let last = model.points[model.points.count - 1].start
        guard first != last else { return first.addingTimeInterval(-86_400)...first.addingTimeInterval(86_400) }
        return first...last
    }

    private func tooltip(_ point: QuestionSeries.Point) -> some View {
        let unit = unit.map { " \($0)" } ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(ChartFormat.bucket(point.start, series.bucket, style: .long)).font(.qr(.caption)).bold()
            Text("avg \(ChartFormat.number(point.mean))\(unit)").font(.qr(.monoCaption))
            Text("\(ChartFormat.number(point.min))–\(ChartFormat.number(point.max)) · n=\(point.count)")
                .font(.qr(.monoCaption))
                .foregroundStyle(.qr.muted)
        }
        .padding(8)
        .background(.qr.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.qr.line))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func accessibilitySummary(_ model: LineChartModel) -> String {
        model.points.map {
            "\(ChartFormat.bucket($0.start, series.bucket, style: .long)): \(ChartFormat.number($0.mean))"
        }
        .joined(separator: ", ")
    }
}

// MARK: - Stacked bars (enum)

/// Counts per option per bucket, stacked, with a legend and a per-bucket tooltip (`StackedBars`).
struct OptionStackChart: View {
    let series: QuestionSeries
    let options: [EnumOption]
    let label: String
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                if let model = StackedBarsModel(series: series.points, options: options, width: proxy.size.width) {
                    chart(model)
                } else {
                    NoAnswers()
                }
            }
            .frame(height: StackedBarsModel.height)
            if let model = StackedBarsModel(series: series.points, options: options, width: 320), model.legend.count > 1
            {
                legend(model)
            }
        }
    }

    private func id(_ point: QuestionSeries.Point) -> String { point.start.ISO8601Format() }

    private func chart(_ model: StackedBarsModel) -> some View {
        let labelled = Set(model.labelled.map { id(model.points[$0]) })
        let colors = model.legend.map { optionColor($0.value, in: options) }
        let shown = selected.flatMap { selected in model.points.first { id($0) == selected } }
        return Chart {
            ForEach(model.points, id: \.start) { point in
                ForEach(model.segments(point), id: \.value) { segment in
                    BarMark(x: .value("Bucket", id(point)), y: .value("Count", segment.count))
                        .foregroundStyle(by: .value("Option", segment.value))
                        .opacity(shown == nil || shown?.start == point.start ? 1 : 0.55)
                }
            }
        }
        .chartForegroundStyleScale(domain: model.legend.map(\.value), range: colors)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...model.max)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: model.points.map(id).filter { labelled.contains($0) }) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let point = model.points.first(where: { id($0) == key }) {
                        Text(ChartFormat.bucket(point.start, series.bucket)).font(.qr(.caption))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartOverlay { _ in
            if let shown { tooltip(shown, model) }
        }
        .accessibilityLabel("\(label): answers per \(series.bucket.rawValue)")
        .accessibilityValue(
            model.points.map { point in
                "\(ChartFormat.bucket(point.start, series.bucket, style: .long)): "
                    + model.segments(point).map { s in "\(legendLabel(s.value, model)) \(s.count)" }.joined(
                        separator: ", ")
            }
            .joined(separator: "; "))
    }

    private func legendLabel(_ value: String, _ model: StackedBarsModel) -> String {
        model.legend.first { $0.value == value }?.label ?? value
    }

    private func tooltip(_ point: QuestionSeries.Point, _ model: StackedBarsModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ChartFormat.bucket(point.start, series.bucket, style: .long)).font(.qr(.caption)).bold()
            ForEach(model.segments(point), id: \.value) { segment in
                HStack(spacing: 6) {
                    Circle().fill(optionColor(segment.value, in: options)).frame(width: 8, height: 8)
                    Text(legendLabel(segment.value, model)).font(.qr(.caption)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(segment.count)").font(.qr(.monoCaption))
                }
            }
        }
        .padding(8)
        .frame(width: 170)
        .background(.qr.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.qr.line))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func legend(_ model: StackedBarsModel) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 4) {
            ForEach(model.legend, id: \.value) { item in
                HStack(spacing: 6) {
                    Circle().fill(optionColor(item.value, in: options)).frame(width: 10, height: 10)
                    Text(item.label).font(.qr(.caption)).foregroundStyle(.qr.inkSoft)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Option bars (enum)

/// One bar per option, labelled with its count and share; archived options struck through
/// (`EnumBars`).
struct OptionBars: View {
    let options: [QuestionStats.OptionCount]
    let all: [EnumOption]

    var body: some View {
        let max = Swift.max(1, options.map(\.count).max() ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(options, id: \.option.value) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(optionColor(item.option.value, in: all)).frame(width: 10, height: 10)
                        Text(item.option.label)
                            .font(.qr(.callout))
                            .strikethrough(item.option.archived)
                            .foregroundStyle(item.option.archived ? Color.qr.muted : Color.qr.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("**\(ChartFormat.count(item.count))** · \(ChartFormat.percent(item.share))")
                            .font(.qr(.monoCaption))
                            .foregroundStyle(.qr.inkSoft)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Color.qr.sunken)
                            .overlay(alignment: .leading) {
                                Capsule().fill(optionColor(item.option.value, in: all))
                                    .frame(width: proxy.size.width * Double(item.count) / Double(max))
                            }
                    }
                    .frame(height: 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.option.label + (item.option.archived ? ", archived" : ""))
                .accessibilityValue("\(item.count), \(ChartFormat.percent(item.share))")
            }
        }
    }
}

// MARK: - Histogram (int, double)

/// The distribution, one bar per bin; tap a bar for its range and count (`Histogram`).
struct DistributionChart: View {
    let bins: [QuestionStats.HistogramBin]
    let unit: String?
    let label: String
    @State private var selected: Int?

    var body: some View {
        let unit = unit.map { " \($0)" } ?? ""
        let shown = selected.flatMap { bins.indices.contains($0) ? bins[$0] : nil }
        VStack(alignment: .leading, spacing: 4) {
            Text(
                shown.map {
                    "\(ChartFormat.number($0.lower))–\(ChartFormat.number($0.upper))\(unit): \(ChartFormat.count($0.count))"
                } ?? "Distribution"
            )
            .font(.qr(.caption))
            .foregroundStyle(.qr.muted)
            Chart {
                ForEach(Array(bins.enumerated()), id: \.offset) { index, bin in
                    BarMark(x: .value("Bin", index), y: .value("Count", bin.count))
                        .foregroundStyle(Color.qr.accent.opacity(selected == nil || selected == index ? 0.85 : 0.4))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: $selected)
            .frame(height: 100)
            if let first = bins.first, let last = bins.last {
                HStack {
                    Text(ChartFormat.tick(first.lower))
                    Spacer()
                    Text("\(ChartFormat.tick(last.upper))\(unit)")
                }
                .font(.qr(.caption))
                .foregroundStyle(.qr.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Histogram of \(label)")
        .accessibilityValue(
            bins.map { "\(ChartFormat.number($0.lower))–\(ChartFormat.number($0.upper)): \($0.count)" }
                .joined(separator: ", "))
    }
}

// MARK: - Layout

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
