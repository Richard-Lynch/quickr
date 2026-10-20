import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import UserNotifications

/// Where the home screen's buttons go. LINKS (routes), RECORD, SETTINGS and SYNC-UX fill these in;
/// until then they do nothing.
struct HomeActions {
    var open: (ViewTopic) -> Void = { _ in }
    var record: (ViewTopic) -> Void = { _ in }
    var newTopic: () -> Void = {}
    var settings: () -> Void = {}
    var onboarding: () -> Void = {}
    var sync: () -> Void = {}
}

/// The home screen (the PWA's `TopicsPage`): "Due now", then every topic with search, a status
/// filter and the sorts, "Coming up" and the rest. Tiles are TILES's `TopicTile`.
struct HomeView: View {
    let session: AppSession
    var actions = HomeActions()
    @State private var model: HomeModel
    @State private var filtersOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    init(session: AppSession, actions: HomeActions = HomeActions()) {
        self.session = session
        self.actions = actions
        _model = State(initialValue: HomeModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .qrPaperBackground()
        .accessibilityIdentifier("home.list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: ObservationKey(binding: session.binding, attempt: model.attempt)) { await model.observe() }
        .task {
            // The PWA's `useNow`: due states and labels move with the clock.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.tick() }
        }
        .onChange(of: model.badgeCount, initial: true) { _, count in
            // Fails quietly until notifications are authorized (M3).
            UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
        }
    }

    private struct ObservationKey: Hashable {
        var binding: AppSession.Binding?
        var attempt: Int
    }

    // MARK: - Header

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text("quickR")
                .font(.qr(.title))
                .foregroundStyle(.qr.ink)
                .accessibilityLabel("quickR — all topics")
                .accessibilityAddTraits(.isHeader)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            SyncPill(
                online: model.isOnline, pending: model.pendingCount, failed: model.failedCount, action: actions.sync
            )
            .accessibilityIdentifier("home.syncPill")
            Button(action: actions.newTopic) { QIcon.plus.view(size: 18, weight: .semibold) }
                .accessibilityLabel("New topic")
                .accessibilityIdentifier("home.newTopic")
            Button(action: actions.settings) { QIcon.settings.view(size: 18) }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settings")
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let error = bannerError {
            ErrorBanner(message: error) { Task { await model.retry() } }
        }
        switch model.phase {
        case .noServer:
            EmptyStateView(
                icon: .phone, title: "Connect to your server",
                message: "Add your quickR server’s address to start tracking.",
                identifier: "home.noServer"
            ) {
                PrimaryButton("Connect a server", icon: .plus, action: actions.onboarding)
            }
        case .loading, .offline:
            if model.isOfflineWithoutData {
                EmptyStateView(
                    icon: .cloudOff, title: "You’re offline",
                    message:
                        "Topics will appear here once you’re back online. Next time they’ll be saved on this device.",
                    identifier: "home.offline")
            } else {
                skeletons
            }
        case .failed:
            EmptyView()  // the banner says it
        case .ready:
            if model.rows.isEmpty && !model.isFiltered {
                EmptyStateView(
                    icon: .layers, title: "Track anything",
                    message:
                        "A topic is a little form you fill in over and over — sleep, workouts, moods, plants. Every entry becomes data you can chart.",
                    identifier: "home.empty"
                ) {
                    PrimaryButton("Create your first topic", icon: .plus, action: actions.newTopic)
                }
            } else {
                list
            }
        }
    }

    private var bannerError: String? {
        if case .failed(let message) = model.phase { return message }
        return model.loadError
    }

    @ViewBuilder private var list: some View {
        if model.isSectioned {
            HomeSection(
                title: "Due now", count: model.sections.due.count, tone: .accent, identifier: "home.section.due"
            ) {
                if model.sections.due.isEmpty {
                    CaughtUp()
                } else {
                    tiles(model.sections.due)
                }
            }
        }
        heading
        searchRow
        if filtersOpen { filterPanel }
        if model.isSectioned {
            if !model.sections.upcoming.isEmpty {
                HomeSection(
                    title: "Coming up", count: model.sections.upcoming.count, identifier: "home.section.upcoming"
                ) {
                    tiles(model.sections.upcoming)
                }
            }
            if !model.sections.other.isEmpty {
                HomeSection(
                    title: model.sections.upcoming.isEmpty ? "All" : "Unscheduled", count: model.sections.other.count,
                    identifier: "home.section.other"
                ) {
                    tiles(model.sections.other)
                }
            }
        } else if model.rows.isEmpty {
            EmptyStateView(
                icon: .search, title: "No matches", message: "Try another search or status filter.",
                identifier: "home.noMatches")
        } else {
            tiles(model.rows)
        }
    }

    private func tiles(_ rows: [HomeModel.Row]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(rows, id: \.value.id) { row in
                TopicTile(
                    topic: row.value, now: model.now, onOpen: { actions.open(row.value) },
                    onRecord: { actions.record(row.value) })
            }
        }
    }

    private var heading: some View {
        let count = model.rows.count
        let noun = model.status == .archived ? "archived topic" : "topic"
        return AdaptiveStack(vertical: typeSize.isAccessibilitySize, spacing: 8) {
            Text(model.isSectioned ? "Topics" : "All topics")
                .font(.qr(.largeTitle))
                .foregroundStyle(.qr.ink)
                .accessibilityAddTraits(.isHeader)
            Text("\(count.formatted()) \(count == 1 ? noun : noun + "s")")
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
                .accessibilityIdentifier("home.count")
        }
        .padding(.top, 4)
    }

    private var searchRow: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                QIcon.search.view(size: 16).foregroundStyle(.qr.muted).accessibilityHidden(true)
                TextField("Search topics and questions", text: $model.search)
                    .font(.qr(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel("Search topics")
                    .accessibilityIdentifier("home.search")
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        QIcon.x.view(size: 14, weight: .bold)
                    }
                    .foregroundStyle(.qr.muted)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: QuickrMetrics.tapTarget)
            .background(Color.qr.surface, in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius).strokeBorder(Color.qr.line, lineWidth: 1)
            }
            Button {
                withAnimation(.snappy) { filtersOpen.toggle() }
            } label: {
                QIcon.list.view(size: 18, weight: .semibold)
                    .frame(width: QuickrMetrics.tapTarget, height: QuickrMetrics.tapTarget)
                    .foregroundStyle(filtersOpen || model.hasNonDefaultFilter ? Color.qr.accentStrong : .qr.inkSoft)
                    .background(
                        filtersOpen || model.hasNonDefaultFilter ? Color.qr.accentSoft : .qr.surface,
                        in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuickrPressStyle(scale: 0.95))
            .accessibilityLabel("Filter and sort")
            .accessibilityValue(filtersOpen ? "Shown" : "Hidden")
            .accessibilityIdentifier("home.filter")
        }
    }

    private var filterPanel: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                Picker("Status", selection: $model.status) {
                    ForEach(TopicStatusFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("home.status")
            } else {
                Picker("Status", selection: $model.status) {
                    ForEach(TopicStatusFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("home.status")
            }
            HStack {
                Text("Sort").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                Spacer()
                Picker("Sort", selection: $model.sort) {
                    ForEach(TopicSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.qr.ink)
                .accessibilityIdentifier("home.sort")
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var skeletons: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius)
                    .fill(Color.qr.sunken)
                    .frame(height: 128)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading topics")
        .accessibilityIdentifier("home.loading")
    }
}

// MARK: - Pieces

/// A section: an uppercase title with a count, then its tiles.
private struct HomeSection<Content: View>: View {
    let title: String
    let count: Int
    var tone: Tone = .plain
    let identifier: String
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    enum Tone { case plain, accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if tone == .accent {
                    Circle()
                        .fill(Color.qr.accent)
                        .frame(width: 8, height: 8)
                        .opacity(count > 0 && pulse ? 0.35 : 1)
                        .accessibilityHidden(true)
                        .onAppear {
                            guard count > 0, !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1).repeatForever()) { pulse = true }
                        }
                }
                Text(title.uppercased())
                    .font(.qr(.label))
                    .tracking(0.8)
                    .foregroundStyle(tone == .accent ? Color.qr.accentStrong : .qr.muted)
                Text(count.formatted())
                    .font(.qr(.monoCaption))
                    .foregroundStyle(.qr.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
            content
        }
    }
}

private struct CaughtUp: View {
    var body: some View {
        HStack(spacing: 8) {
            QIcon.check.view(size: 16, weight: .heavy).foregroundStyle(.qr.ok)
            Text("Nothing due — you’re all caught up.")
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius)
                .strokeBorder(Color.qr.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.caughtUp")
    }
}

private struct EmptyStateView<Action: View>: View {
    let icon: QIcon
    let title: String
    let message: String
    let identifier: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 12) {
            icon.view(size: 36).foregroundStyle(.qr.muted).accessibilityHidden(true)
            Text(title)
                .font(.qr(.title))
                .foregroundStyle(.qr.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.qr(.body))
                .foregroundStyle(.qr.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action.padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(icon: QIcon, title: String, message: String, identifier: String) {
        self.init(icon: icon, title: title, message: message, identifier: identifier) { EmptyView() }
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Could not load topics").font(.qr(.label))
            } icon: {
                QIcon.alert.view(size: 16, weight: .bold)
            }
            .foregroundStyle(.qr.danger)
            Text(message)
                .font(.qr(.footnote))
                .foregroundStyle(.qr.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .buttonStyle(.qr(.secondary, size: .small))
                .accessibilityIdentifier("home.retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.qr.dangerSoft, in: RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.error")
    }
}

/// An HStack, or a VStack at accessibility text sizes.
private struct AdaptiveStack<Content: View>: View {
    let vertical: Bool
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        if vertical {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: spacing) { content }
        }
    }
}
