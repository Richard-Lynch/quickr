import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The Overview's cards (the PWA's `Summary` and `QuestionCard` in `OverviewPage`).

/// Entries, latest, first and the top sources.
struct StatsSummaryCard: View {
    let stats: TopicStats
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Card {
            let columns = typeSize.isAccessibilitySize ? 1 : 2
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                let tiles = self.tiles
                ForEach(0..<((tiles.count + columns - 1) / columns), id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < tiles.count { tiles[index] } else { Color.clear.frame(height: 0) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("overview.summary")
    }

    private var tiles: [AnyView] {
        [
            AnyView(tile("Entries", ChartFormat.count(stats.entryCount), big: true)),
            AnyView(tile("Latest", stats.lastCapturedAt.map(Self.relative) ?? "never")),
            AnyView(tile("First", stats.firstCapturedAt.map { ChartFormat.date($0) } ?? "—")),
            AnyView(sources),
        ]
    }

    private func tile(_ label: String, _ value: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.qr(.caption)).foregroundStyle(.qr.muted)
            Text(value)
                .font(big ? .qr(.monoRegular, size: 30, relativeTo: .largeTitle).bold() : .qr(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.qr(.caption)).foregroundStyle(.qr.muted)
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(stats.sources.prefix(4), id: \.value) { source in
                    QuickrBadge("\(source.value) \(source.count)")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The PWA's `formatRelative`: "2 hours ago", "yesterday".
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One question's card: its label and key, "retired" when the topic no longer asks it, how many
/// entries answered it, then the numeric, enum or text body.
struct QuestionStatsCard: View {
    let stats: QuestionStats
    /// The question in the topic's current version; nil when it was retired.
    let question: Question?
    let series: OverviewModel.Load<QuestionSeries>?
    let bucket: QuestionSeries.Bucket
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                header
                switch stats {
                case .numeric(let numeric): numericBody(numeric)
                case .choice(let choice): choiceBody(choice)
                case .text(let text): textBody(text)
                }
            }
        }
        .accessibilityIdentifier("overview.card.\(stats.key)")
    }

    private var label: String {
        switch stats {
        case .numeric(let s): s.label
        case .choice(let s): s.label
        case .text(let s): s.label
        }
    }

    private var answered: (Int, Int) {
        switch stats {
        case .numeric(let s): (s.count, s.count + s.missing)
        case .choice(let s): (s.count, s.count + s.missing)
        case .text(let s): (s.count, s.count + s.missing)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.qr(.section)).accessibilityAddTraits(.isHeader)
                Text(stats.key).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
            }
            Spacer(minLength: 8)
            if question == nil { QuickrBadge("retired", tone: .warn) }
            QuickrBadge("\(answered.0)/\(answered.1)")
                .accessibilityLabel("\(answered.0) of \(answered.1) entries answered")
        }
    }

    // MARK: Numeric

    private var unit: String? {
        switch question?.kind {
        case .int(let spec): spec.unit
        case .double(let spec): spec.unit
        default: nil
        }
    }

    private func numericBody(_ s: QuestionStats.Numeric) -> some View {
        let dec = s.type == .int ? 1 : 2
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ChartFormat.number(s.mean, maxDecimals: dec))
                    .font(.qr(.monoRegular, size: 36, relativeTo: .largeTitle).bold())
                Text("avg" + (unit.map { " \($0)" } ?? "")).font(.qr(.subheadline)).foregroundStyle(.qr.muted)
            }
            .accessibilityElement(children: .combine)
            let rows: [(String, Double?)] = [
                ("Median", s.median), ("Min", s.min), ("Max", s.max), ("Std dev", s.stddev), ("Sum", s.sum),
            ]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), alignment: .leading)], alignment: .leading, spacing: 8)
            {
                ForEach(rows, id: \.0) { name, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.uppercased()).font(.qr(.caption)).foregroundStyle(.qr.muted)
                        Text(ChartFormat.number(value, maxDecimals: dec)).font(.qr(.mono)).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(12)
            .background(Color.qr.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            if !s.histogram.isEmpty { DistributionChart(bins: s.histogram, unit: unit, label: s.label) }
            seriesSection("Average per \(bucket.rawValue)") { series in
                MeanLineChart(series: series, unit: unit, label: s.label)
            }
        }
    }

    // MARK: Enum

    private func choiceBody(_ s: QuestionStats.Choice) -> some View {
        let view = ChoiceView(s)
        let options = s.options.map(\.option)
        return VStack(alignment: .leading, spacing: 12) {
            if let top = view.top {
                Text(
                    "Most often **\(top.option.label)** (\(ChartFormat.percent(top.share))\(s.multiple ? " of entries" : ""))"
                )
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
            }
            if s.multiple {
                HStack(spacing: 6) {
                    QuickrBadge("multi-select", tone: .info)
                    Text("Share of entries that picked each option — can add up to more than 100%.")
                        .font(.qr(.caption))
                        .foregroundStyle(.qr.muted)
                }
            }
            OptionBars(options: view.visible, all: options)
            seriesSection("\(s.multiple ? "Selections" : "Answers") per \(bucket.rawValue)") { series in
                OptionStackChart(series: series, options: options, label: s.label)
            }
        }
    }

    // MARK: Text

    private func textBody(_ s: QuestionStats.Text) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ChartFormat.plural(s.distinct, "distinct answer")).font(.qr(.subheadline)).foregroundStyle(.qr.muted)
            if s.top.contains(where: { $0.count > 1 }) {
                let maxTop = max(1, s.top.map(\.count).max() ?? 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Most common").font(.qr(.caption)).bold().foregroundStyle(.qr.inkSoft)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(s.top.prefix(5), id: \.value) { item in
                        HStack {
                            // One line beside the count, or wrapped at accessibility sizes.
                            Text(item.value).lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                            Spacer(minLength: 8)
                            Text("\(item.count)").font(.qr(.monoCaption)).foregroundStyle(.qr.inkSoft)
                        }
                        .font(.qr(.callout))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(alignment: .leading) {
                            GeometryReader { proxy in
                                Color.qr.accent.opacity(0.12)
                                    .frame(width: proxy.size.width * Double(item.count) / Double(maxTop))
                            }
                        }
                        .background(Color.qr.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.value)
                        .accessibilityValue(ChartFormat.plural(item.count, "answer"))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent").font(.qr(.caption)).bold().foregroundStyle(.qr.inkSoft)
                    .accessibilityAddTraits(.isHeader)
                if s.recent.isEmpty {
                    Text("No answers in this range.").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                } else {
                    ForEach(s.recent.prefix(5), id: \.entryId) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.value).font(.qr(.callout)).lineLimit(3)
                            Text(StatsSummaryCard.relative(item.capturedAt)).font(.qr(.caption)).foregroundStyle(
                                .qr.muted)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Series

    @ViewBuilder private func seriesSection<Chart: View>(
        _ title: String, @ViewBuilder chart: @escaping (QuestionSeries) -> Chart
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.qr(.caption)).bold().foregroundStyle(.qr.inkSoft)
            switch series {
            case .loaded(let value, let freshness):
                // Its own fetch may have failed while the summary's didn't.
                if case .stale = freshness { StatsFreshnessLabel(freshness: freshness, id: "overview.seriesStale") }
                chart(value)
            case .unavailable(let reason):
                Text(reason.message).font(.qr(.subheadline)).foregroundStyle(.qr.danger)
            case .loading, nil:
                RoundedRectangle(cornerRadius: 12).fill(Color.qr.sunken).frame(height: 150)
                    .accessibilityLabel("Loading")
            }
        }
    }
}

/// "Last updated 5 minutes ago" under stale (offline) stats, or "Updating…" while a fetch for
/// cached ones runs.
struct StatsFreshnessLabel: View {
    let freshness: OverviewModel.Freshness
    var id = "overview.stale"

    var body: some View {
        switch freshness {
        case .fresh:
            EmptyView()
        case .updating:
            Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
                .font(.qr(.caption))
                .foregroundStyle(.qr.muted)
                .accessibilityIdentifier("overview.updating")
        case .stale(let fetchedAt, let reason):
            HStack(spacing: 6) {
                QIcon.cloudOff.view(size: 14, weight: .semibold)
                Text("Last updated \(StatsSummaryCard.relative(fetchedAt))")
                if reason != .offline { Text("· \(reason.message)") }
            }
            .font(.qr(.caption))
            .foregroundStyle(.qr.warn)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
        }
    }
}
