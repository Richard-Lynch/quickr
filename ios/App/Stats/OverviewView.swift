import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A topic's Overview tab (the PWA's `OverviewPage`): the filters it shares with Entries and the
/// chart bucket, then the summary and a card per question. Stats and series are the server's,
/// cached per store; offline the cached ones show with "Last updated".
struct OverviewView: View {
    let session: AppSession
    let ref: TopicLinkRef
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var topic: ViewTopic?
    @State private var resolved = false
    @State private var model: OverviewModel?
    @State private var modelKey: ModelKey?
    /// A picked bucket holds for the range it was picked in (the PWA's `bucketChoice`).
    @State private var bucketChoice: BucketChoice?
    /// The range starts from today: moved on activation.
    @State private var now = Date()
    /// The reader's zone, which series are bucketed and labelled in: a change reloads them.
    @State private var timeZone = TimeZone.current.identifier
    /// The pull to refresh in flight. Unstructured, so SwiftUI updating the view doesn't cancel
    /// it; the model drops its answer if the store changed meanwhile.
    @State private var refreshing: Task<Void, Never>?

    private struct BucketChoice: Equatable {
        var range: EntryRange
        var bucket: QuestionSeries.Bucket
    }

    /// One model per topic and store: another store (a server switch, a reset) starts over.
    private struct ModelKey: Hashable {
        var topicId: UUID
        var binding: AppSession.Binding?
    }

    private struct LoadKey: Hashable {
        var model: ModelKey?
        var query: StatsQuery
        var bucket: QuestionSeries.Bucket
        var timeZone: String
    }

    private var filters: EntryListFilters { environment.topicFilters[ref.rawValue] ?? EntryListFilters() }

    private var bucket: QuestionSeries.Bucket {
        if let bucketChoice, bucketChoice.range == filters.range { return bucketChoice.bucket }
        return filters.range.defaultChartBucket
    }

    private var query: StatsQuery { StatsQuery(filters, now: now, calendar: .autoupdatingCurrent) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .qrPaperBackground()
        .accessibilityIdentifier("overview.list")
        // Unstructured: SwiftUI cancels a refresh's own task when the view updates under it.
        .refreshable { [weak model, query, bucket] in
            let task = Task { [weak model] in
                guard let model else { return }
                await model.load(query: query, bucket: bucket)
            }
            refreshing = task
            await task.value
        }
        // Gone for good (or another tab): an unfinished refresh stops, putting back what it replaced.
        .onDisappear { refreshing?.cancel() }
        .task(id: session.binding) { await observeTopic() }
        .task(
            id: LoadKey(
                model: topic.map { ModelKey(topicId: $0.topic.id, binding: session.binding) }, query: query,
                bucket: bucket, timeZone: timeZone)
        ) {
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                now = Date()
                timeZone = TimeZone.current.identifier
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            timeZone = TimeZone.current.identifier
        }
    }

    // MARK: - Loading

    private func observeTopic() async {
        topic = nil
        resolved = false
        guard let store = session.store else {
            resolved = true
            return
        }
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                // By id once found: a slug can change.
                let found = topics.first { candidate in
                    topic.map { candidate.topic.id == $0.topic.id } ?? candidate.matches(ref: ref.rawValue)
                }
                topic = found
                resolved = true
            }
        } catch {
            resolved = true
        }
    }

    private func load() async {
        guard let topic else { return }
        let key = ModelKey(topicId: topic.topic.id, binding: session.binding)
        if model == nil || modelKey != key {
            let session = session
            model = OverviewModel(topicId: topic.topic.id, ref: topic.topic.slug) { session.stats }
            modelKey = key
        }
        await model?.load(query: query, bucket: bucket)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let filters = Binding(
                get: { self.filters }, set: { environment.topicFilters[ref.rawValue] = $0 })
            QuickrSegmentedPicker("Date range", selection: filters.range, valueLabel: self.filters.range.label) {
                ForEach(EntryRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("overview.range")
            // Side by side, or stacked at accessibility sizes, where two menus don't fit a line.
            let menus =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            menus {
                if versionChoices.count > 0 {
                    Picker("Version", selection: filters.version) {
                        Text("All versions").tag(Int?.none)
                        ForEach(versionChoices, id: \.self) { Text("v\($0)").tag(Int?.some($0)) }
                    }
                    .pickerStyle(.menu)
                    .tint(.qr.ink)
                    .accessibilityIdentifier("overview.version")
                }
                if sourceChoices.count > 1 || self.filters.source != nil {
                    Picker("Source", selection: filters.source) {
                        Text("All sources").tag(String?.none)
                        ForEach(sourceChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu)
                    .tint(.qr.ink)
                    .accessibilityIdentifier("overview.source")
                }
                Spacer(minLength: 0)
            }
            QuickrSegmentedPicker(
                "Chart bucket",
                selection: Binding(
                    get: { bucket }, set: { bucketChoice = BucketChoice(range: self.filters.range, bucket: $0) }),
                valueLabel: bucket.rawValue.capitalized
            ) {
                Text("Day").tag(QuestionSeries.Bucket.day)
                Text("Week").tag(QuestionSeries.Bucket.week)
                Text("Month").tag(QuestionSeries.Bucket.month)
            }
            .accessibilityIdentifier("overview.bucket")
        }
    }

    private var versionChoices: [Int] {
        let current = topic?.topic.currentVersion ?? 1
        return current > 1 ? Array((1...current).reversed()) : []
    }

    /// The topic's sources (unfiltered); the selected one always listed.
    private var sourceChoices: [String] {
        var values = model?.sources ?? []
        if let selected = filters.source, !values.contains(selected) { values.append(selected) }
        return values
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if resolved && topic == nil {
            StatsMessage(
                title: "Topic not found", text: "It may have been deleted, or it's on another server.",
                id: "overview.missing"
            ) { EmptyView() }
        } else if let topic, let model {
            switch model.stats {
            case .loading:
                skeleton
            case .unavailable(let reason):
                StatsMessage(title: "Could not load stats", text: reason.message, id: "overview.error") {
                    PrimaryButton("Try again", icon: .sync, size: .medium) {
                        Task { await model.load(query: query, bucket: bucket) }
                    }
                }
            case .loaded(let stats, let freshness):
                StatsFreshnessLabel(freshness: freshness)
                if stats.entryCount == 0 {
                    empty(topic)
                } else {
                    StatsSummaryCard(stats: stats)
                    TimingOverviewSection(timing: model.timing, timed: topic.topic.timer != nil)
                    ForEach(stats.questions, id: \.key) { question in
                        QuestionStatsCard(
                            stats: question, question: topic.topic.questions.first { $0.key == question.key },
                            series: model.series[question.key], bucket: bucket)
                    }
                }
            }
        } else {
            skeleton
        }
    }

    private var skeleton: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius).fill(Color.qr.sunken).frame(height: 96)
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius).fill(Color.qr.sunken).frame(height: 260)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading stats")
        .accessibilityIdentifier("overview.loading")
    }

    @ViewBuilder private func empty(_ topic: ViewTopic) -> some View {
        let never = topic.topic.entryCount == 0
        StatsMessage(
            title: never ? "No data yet" : "Nothing in this range",
            text: never ? "Charts and stats appear as soon as you log an entry." : "Try a wider date range.",
            id: "overview.empty"
        ) {
            if never && topic.topic.status == .active {
                PrimaryButton("Log the first entry", icon: .plus, size: .medium) {
                    environment.router.open(.record(ref))
                }
            }
        }
    }
}

/// A centred title, text and optional action in the Overview's place.
private struct StatsMessage<Action: View>: View {
    let title: String
    let text: String
    let id: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            QIcon.chart.view(size: 36, weight: .regular).foregroundStyle(.qr.muted)
            Text(title).font(.qr(.title)).foregroundStyle(.qr.ink).accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.qr(.body))
                .foregroundStyle(.qr.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}
