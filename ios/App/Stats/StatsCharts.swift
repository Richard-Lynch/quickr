import Charts
import QuickrCore
import QuickrData
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

/// How much the chart's text has grown with Dynamic Type (1 at the default size). Charts grow by
/// it, up to twice their height, so axis labels still fit (a11y audit ST5), and label buckets by
/// it, so the larger labels keep their gap.
struct ChartTextScale: DynamicProperty {
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var height: CGFloat { min(max(scale, 1), 2) }
    /// The width to lay the model's labels out in: narrower as the text grows.
    func labelWidth(_ width: CGFloat) -> CGFloat { width / max(scale, 1) }
}

// MARK: - Line (int, double)

/// The mean per bucket as a line over a soft min–max band, with a tap-and-drag tooltip
/// (`LineChart`).
struct MeanLineChart: View {
    let series: QuestionSeries
    let unit: String?
    let label: String
    @State private var selected: Date?
    private let textScale = ChartTextScale()

    var body: some View {
        GeometryReader { proxy in
            if let model = LineChartModel(series: series.points, width: textScale.labelWidth(proxy.size.width)) {
                chart(model)
            } else {
                NoAnswers()
            }
        }
        .frame(height: LineChartModel.height * textScale.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chart.line")
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
                    // The band is in each point's label; one element per bucket (ST3).
                    .accessibilityHidden(true)
                    LineMark(x: .value("Bucket", point.start), y: .value("Mean", point.mean ?? 0))
                        .foregroundStyle(Color.qr.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .accessibilityHidden(model.points.count <= 40)
                        .accessibilityLabel(spokenBucket(point.start, series.bucket))
                        .accessibilityValue(pointValue(point))
                }
                if model.points.count <= 40 {
                    PointMark(x: .value("Bucket", point.start), y: .value("Mean", point.mean ?? 0))
                        .foregroundStyle(Color.qr.accent)
                        .symbolSize(shown?.start == point.start ? 100 : 50)
                        .accessibilityLabel(spokenBucket(point.start, series.bucket))
                        .accessibilityValue(pointValue(point))
                }
            }
            if let shown {
                RuleMark(x: .value("Bucket", shown.start)).foregroundStyle(Color.qr.ink.opacity(0.4))
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: model.domain)
        .padding(.top, 8)
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
        .accessibilityChartDescriptor(
            MeanLineDescriptor(
                title: "\(label): average per \(series.bucket.rawValue)", points: model.points, bucket: series.bucket,
                unit: unit, domain: model.domain))
    }

    private func pointValue(_ point: QuestionSeries.Point) -> String {
        let unit = unit.map { " \($0)" } ?? ""
        return "average \(ChartFormat.number(point.mean))\(unit), "
            + "\(ChartFormat.number(point.min)) to \(ChartFormat.number(point.max)), "
            + ChartFormat.plural(point.count, "answer")
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
}

// MARK: - Stacked bars (enum)

/// Counts per option per bucket, stacked, with a legend and a per-bucket tooltip (`StackedBars`).
struct OptionStackChart: View {
    let series: QuestionSeries
    let options: [EnumOption]
    let label: String
    @State private var selected: String?
    private let textScale = ChartTextScale()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                if let model = StackedBarsModel(
                    series: series.points, options: options, width: textScale.labelWidth(proxy.size.width))
                {
                    chart(model)
                } else {
                    NoAnswers()
                }
            }
            .frame(height: StackedBarsModel.height * textScale.height)
            if let model = StackedBarsModel(series: series.points, options: options, width: 320), model.legend.count > 1
            {
                legend(model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chart.stacked")
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
                        // The bucket's date and the option, not the x value's ISO string (ST2).
                        .accessibilityLabel(spokenBucket(point.start, series.bucket))
                        .accessibilityValue("\(legendLabel(segment.value, model)) \(segment.count)")
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
                        Text(ChartFormat.bucket(point.start, series.bucket)).font(.qr(.caption)).fixedSize()
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartOverlay { _ in
            if let shown { tooltip(shown, model) }
        }
        .accessibilityLabel("\(label): answers per \(series.bucket.rawValue)")
        .accessibilityChartDescriptor(
            OptionStackDescriptor(
                title: "\(label): answers per \(series.bucket.rawValue)", model: model, bucket: series.bucket))
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
    private let textScale = ChartTextScale()

    /// Bins are categories ("0" … "9"), so each bar fills its slot.
    private var selectedBin: Binding<String?> {
        Binding(get: { selected.map(String.init) }, set: { selected = $0.flatMap(Int.init) })
    }

    var body: some View {
        let unit = unit.map { " \($0)" } ?? ""
        let shown = selected.flatMap { bins.indices.contains($0) ? bins[$0] : nil }
        let categories = DistributionDescriptor.categories(bins, unit: self.unit)
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
                    BarMark(x: .value("Bin", String(index)), y: .value("Count", bin.count), width: .ratio(0.9))
                        .foregroundStyle(Color.qr.accent.opacity(selected == nil || selected == index ? 0.85 : 0.4))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .accessibilityLabel(categories[index])
                        .accessibilityValue(ChartFormat.plural(bin.count, "answer"))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: selectedBin)
            .frame(height: 100 * textScale.height)
            .accessibilityLabel("Histogram of \(label)")
            .accessibilityChartDescriptor(
                DistributionDescriptor(title: "Histogram of \(label)", bins: bins, unit: self.unit))
            if let first = bins.first, let last = bins.last {
                HStack {
                    Text(ChartFormat.tick(first.lower))
                    Spacer()
                    Text("\(ChartFormat.tick(last.upper))\(unit)")
                }
                .font(.qr(.caption))
                .foregroundStyle(.qr.muted)
                // The axis ends as one element ("0, 120 min"): text on screen is never hidden.
                .accessibilityElement(children: .combine)
            }
        }
        // The caption, the chart (its bars are elements, ST4) and the axis ends.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chart.histogram")
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

// MARK: - Activity strip

/// "Activity" under the summary (content-display.md §4.2, the PWA's `Activity`): 12 columns of
/// Monday-started weeks × 7 weekdays, oldest left, each cell a local day shaded by its count
/// (0, 1, 2–3, 4+), today outlined, the slots after today blank. From the store's entries, so it
/// ignores the range and the filters. VoiceOver reads a column per week ("Week of 3 Nov: 5
/// entries").
struct ActivityStripCard: View {
    let activity: OverviewModel.Load<ActivityStrip>

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Activity").font(.qr(.section)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let strip = activity.value {
                        Text(strip.caption())
                            .font(.qr(.caption))
                            .foregroundStyle(.qr.muted)
                            .accessibilityIdentifier("overview.activity.caption")
                    }
                }
                switch activity {
                case .loaded(let strip, _):
                    grid(strip)
                case .unavailable(let reason):
                    Text(reason.message).font(.qr(.subheadline)).foregroundStyle(.qr.danger)
                case .loading:
                    RoundedRectangle(cornerRadius: 12).fill(Color.qr.sunken).frame(height: 112)
                        .frame(maxWidth: Self.maxWidth)
                        .accessibilityLabel("Loading")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.activity")
    }

    /// The PWA's `max-w-md`.
    static let maxWidth: CGFloat = 448
    private static let spacing: CGFloat = 4

    private func grid(_ strip: ActivityStrip) -> some View {
        let today = strip.cells.last?.day
        return HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(Array(strip.columns.enumerated()), id: \.offset) { column, week in
                VStack(spacing: Self.spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let index = column * 7 + row
                        if index < strip.cells.count {
                            cell(strip.cells[index], today: strip.cells[index].day == today)
                        } else {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ActivityStrip.spokenWeek(week))
                .accessibilityIdentifier("overview.activity.week.\(column)")
            }
        }
        .frame(maxWidth: Self.maxWidth)
        .accessibilityElement(children: .contain)
        .accessibilityChartDescriptor(ActivityStripDescriptor(strip: strip))
    }

    private func cell(_ cell: ActivityStrip.Cell, today: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Self.fill(cell.level))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if today {
                    RoundedRectangle(cornerRadius: 4).inset(by: -2).stroke(Color.qr.ink, lineWidth: 1.5)
                }
            }
    }

    /// `sunken`, then the accent at 35, 65 and 100 %.
    static func fill(_ level: Int) -> Color {
        switch level {
        case 0: .qr.sunken
        case 1: .qr.accent.opacity(0.35)
        case 2: .qr.accent.opacity(0.65)
        default: .qr.accent
        }
    }
}

// MARK: - Sparkline (int, double)

/// A numeric card's trend beside its mean (content-display.md §4.3, the PWA's `Sparkline`): the
/// means per bucket of the range's default bucket, 48 pt high, the last point marked, max and min
/// as end labels. "Trend unavailable" when its series couldn't load.
struct SparklineView: View {
    let series: OverviewModel.Load<QuestionSeries>?
    let label: String

    var body: some View {
        Group {
            switch series {
            case .loaded(let value, _):
                // The end labels don't depend on the width; the line is laid out in what's left.
                if let model = SparklineModel(series: value.points, width: 1) {
                    trend(model, points: value.points)
                }
            case .unavailable:
                Text("Trend unavailable")
                    .font(.qr(.caption))
                    .foregroundStyle(.qr.danger)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .loading, nil:
                RoundedRectangle(cornerRadius: 8).fill(Color.qr.sunken)
                    .accessibilityLabel("Loading")
            }
        }
        .frame(height: SparklineModel.height)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("overview.sparkline")
    }

    private func trend(_ model: SparklineModel, points: [QuestionSeries.Point]) -> some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                if let laidOut = SparklineModel(series: points, width: proxy.size.width) { line(laidOut) }
            }
            VStack(alignment: .trailing) {
                Text(ChartFormat.number(model.max))
                Spacer(minLength: 0)
                Text(ChartFormat.number(model.min))
            }
            .font(.qr(.monoCaption))
            .foregroundStyle(.qr.muted)
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): trend, last \(ChartFormat.number(model.lastValue))")
        .accessibilityValue("from \(ChartFormat.number(model.min)) to \(ChartFormat.number(model.max))")
    }

    private func line(_ model: SparklineModel) -> some View {
        Canvas { context, _ in
            var path = Path()
            for (index, point) in model.path.enumerated() {
                let at = CGPoint(x: point.x, y: point.y)
                if index == 0 { path.move(to: at) } else { path.addLine(to: at) }
            }
            context.stroke(
                path, with: .color(.qr.accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let r = SparklineModel.pad - 1
            let dot = Path(ellipseIn: CGRect(x: model.last.x - r, y: model.last.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(.qr.accent))
            context.stroke(dot, with: .color(.qr.surface), lineWidth: 1.5)
        }
    }
}
