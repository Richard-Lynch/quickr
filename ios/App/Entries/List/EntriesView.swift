import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A topic's entries (the PWA's `EntriesPage`): the count, the filters (range, version, source),
/// the entries only this device has so far pinned on top, then the server's entries newest
/// first. Swipe to delete, with Undo; tap to edit.
struct EntriesView: View {
    let session: AppSession
    let ref: TopicLinkRef
    @State private var model: EntriesModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    init(session: AppSession, ref: TopicLinkRef) {
        self.session = session
        self.ref = ref
        _model = State(initialValue: EntriesModel(session: session, topicRef: ref.rawValue))
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .qrPaperBackground()
        .accessibilityIdentifier("entries.list")
        .navigationTitle(model.topic?.topic.name ?? ref.rawValue)
        .task(id: ObservationKey(binding: session.binding, attempt: model.attempt)) { await model.observe() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.tick() }
        }
        // The topic's filters are shared with its Overview tab.
        .onAppear {
            if let shared = environment.topicFilters[ref.rawValue] { model.filters = shared }
        }
        .onChange(of: model.filters) { _, filters in environment.topicFilters[ref.rawValue] = filters }
    }

    private struct ObservationKey: Hashable {
        var binding: AppSession.Binding?
        var attempt: Int
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            row {
                VStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius).fill(Color.qr.sunken).frame(height: 96)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Loading entries")
                .accessibilityIdentifier("entries.loading")
            }
        case .noServer:
            row { Message(title: "No server yet", text: "Connect to a server in Settings.", id: "entries.noServer") }
        case .missing:
            row {
                Message(
                    title: "Topic not found", text: "It may have been deleted, or it belongs to another server.",
                    id: "entries.missing")
            }
        case .failed(let message):
            row {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load entries").font(.qr(.label)).foregroundStyle(.qr.danger)
                    Text(message).font(.qr(.footnote)).foregroundStyle(.qr.inkSoft)
                    Button("Retry") { Task { await model.retry() } }
                        .buttonStyle(.qr(.secondary, size: .small))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.qr.dangerSoft, in: RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("entries.error")
            }
        case .ready:
            ready
        }
    }

    @ViewBuilder private var ready: some View {
        row { header }
        ForEach(model.pinned) { pinned in
            row { PendingEntryRow(entry: pinned.entry, columns: model.columns) }
                .onTapGesture { openFix(pinned.entry) }
        }
        if model.rows.isEmpty && model.pinned.isEmpty {
            row { emptyState }
        }
        ForEach(model.rows) { listed in
            row {
                EntryRow(
                    entry: listed.entry, columns: model.columns, currentVersion: model.topic?.topic.currentVersion ?? 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { environment.router.open(.entry(ref, entryId: listed.id)) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edits the entry")
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    delete(listed)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("entry.delete")
            }
            .accessibilityAction(named: "Delete") { delete(listed) }
        }
    }

    /// A list row with the screen's insets and no separators or background.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: - Header and filters

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            Text(countLine)
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
                .accessibilityIdentifier("entries.count")
        }
        .padding(.top, 4)
    }

    /// "12 entries · 2 not synced yet".
    private var countLine: String {
        let text = TopicText()
        let line = text.count(model.rows.count, "entry", "entries")
        return model.pinned.isEmpty ? line : "\(line) · \(model.pinned.count) not synced yet"
    }

    private var filters: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                Picker("Date range", selection: $model.filters.range) {
                    ForEach(EntryRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.qr.ink)
                .accessibilityIdentifier("entries.range")
            } else {
                Picker("Date range", selection: $model.filters.range) {
                    ForEach(EntryRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("entries.range")
            }
            if !model.versionChoices.isEmpty || model.showsSourceFilter {
                HStack(spacing: 8) {
                    if !model.versionChoices.isEmpty {
                        Picker("Version", selection: $model.filters.version) {
                            Text("All versions").tag(Int?.none)
                            ForEach(model.versionChoices, id: \.self) { Text("v\($0)").tag(Int?.some($0)) }
                        }
                        .pickerStyle(.menu)
                        .tint(.qr.ink)
                        .accessibilityIdentifier("entries.version")
                    }
                    if model.showsSourceFilter {
                        Picker("Source", selection: $model.filters.source) {
                            Text("All sources").tag(String?.none)
                            ForEach(sourceChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu)
                        .tint(.qr.ink)
                        .accessibilityIdentifier("entries.source")
                    }
                }
            }
        }
    }

    /// Most entries first; the selected one always listed.
    private var sourceChoices: [String] {
        var values = model.sources.map(\.value)
        if let selected = model.filters.source, !values.contains(selected) { values.append(selected) }
        return values
    }

    @ViewBuilder private var emptyState: some View {
        if model.hasNoEntriesAtAll {
            Message(title: "No entries yet", text: "Entries you log show up here.", id: "entries.empty") {
                if model.topic?.topic.status == .active {
                    PrimaryButton("Log one", icon: .plus, size: .medium) {
                        environment.router.open(.record(ref))
                    }
                }
            }
        } else {
            Message(
                title: "No entries match", text: "Try a wider date range or clear the filters.",
                id: "entries.noMatches")
        }
    }

    // MARK: - Actions

    private func openFix(_ entry: ViewEntry) {
        guard case .failed = entry.syncState else { return }  // a waiting one has nothing to fix
        environment.router.open(.record(ref, fix: entry.id.wireString))
    }

    /// Deletes with Undo, in the store the row was read from: its own binding, captured with it.
    private func delete(_ row: EntriesModel.Row) {
        let deleter = EntryDeleter(environment: environment)
        Task { await deleter.delete(row) }
    }
}

/// The list's delete: in the store the row was read from (`row.binding`, captured when it was
/// rendered), with an Undo toast; a row left over from another store is refused, with a toast.
@MainActor
struct EntryDeleter {
    let writer: SessionEntryWriter
    let toasts: ToastCenter
    let entryToasts: EntryToasts

    init(environment: AppEnvironment) {
        writer = environment.entryWriter
        toasts = environment.toasts
        entryToasts = environment.entryToasts
    }

    func delete(_ row: EntriesModel.Row) async {
        do {
            let scope = try await writer.delete(row.entry, from: row.binding)
            entryToasts.deleted(entryId: row.id, in: scope)
        } catch {
            let message =
                switch writer.failure(error) {
                case .notSaved: "It was already deleted."
                case .scopeChanged: "The server changed; nothing was deleted."
                case .message(let message): message
                }
            _ = toasts.show(Toast("Couldn’t delete", message: message, tone: .danger))
        }
    }
}

// MARK: - Rows

/// One entry the server has: when, the answers, notes, then source, channel and how long ago.
private struct EntryRow: View {
    let entry: ViewEntry
    let columns: [Question]
    let currentVersion: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.qr(.label))
                    .foregroundStyle(.qr.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.entry.version != currentVersion {
                    QuickrBadge("v\(entry.entry.version)").accessibilityLabel("Version \(entry.entry.version)")
                }
                Spacer(minLength: 0)
                SyncBadge(state: entry.syncState)
                QIcon.chevronRight.view(size: 14).foregroundStyle(.qr.muted).accessibilityHidden(true)
            }
            AnswerGrid(entry: entry.entry, columns: columns, oneColumn: typeSize.isAccessibilitySize)
            if !entry.entry.notes.isEmpty {
                Divider().overlay(Color.qr.line)
                Text(entry.entry.notes)
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.inkSoft)
                    .lineLimit(2)
            }
            EntryFooter(entry: entry.entry)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .qrCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("entry.\(entry.id.wireString)")
    }
}

/// An entry only this device has: dashed while it waits to sync; red, with its error, when the
/// server refused it (tap to fix).
private struct PendingEntryRow: View {
    let entry: ViewEntry
    let columns: [Question]
    @Environment(\.dynamicTypeSize) private var typeSize

    private var failed: Bool {
        if case .failed = entry.syncState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.qr(.label))
                .foregroundStyle(.qr.ink)
                .fixedSize(horizontal: false, vertical: true)
            AnswerGrid(entry: entry.entry, columns: columns, oneColumn: typeSize.isAccessibilitySize)
            if failed {
                QuickrBadge("Failed — tap to fix", icon: .alert, tone: .danger)
                if let message = entry.lastError?.message {
                    Text(message)
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                QuickrBadge("Waiting to sync", icon: .clock, tone: .info)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(failed ? Color.qr.dangerSoft.opacity(0.5) : Color.qr.surface.opacity(0.6))
        .overlay {
            RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius)
                .strokeBorder(
                    failed ? Color.qr.danger.opacity(0.5) : Color.qr.lineStrong,
                    style: StrokeStyle(lineWidth: 1, dash: failed ? [] : [5, 4]))
        }
        .clipShape(RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(failed ? .isButton : [])
        .accessibilityHint(failed ? "Opens the entry to fix it" : "")
        .accessibilityIdentifier("pending.\(entry.id.wireString)")
    }
}

/// A server row's own sync state: an edit or delete waiting, or one the server refused.
private struct SyncBadge: View {
    let state: RecordSyncState

    var body: some View {
        switch state {
        case .synced: EmptyView()
        case .pending: QuickrBadge("Waiting", icon: .clock, tone: .info).accessibilityLabel("Change waiting to sync")
        case .failed: QuickrBadge("Not synced", icon: .alert, tone: .danger).accessibilityLabel("Change not synced")
        }
    }
}

/// The answers, two to a row (one at accessibility sizes); lists and text take a whole row.
private struct AnswerGrid: View {
    let entry: Entry
    let columns: [Question]
    let oneColumn: Bool

    private struct Cell: Identifiable {
        let id: String
        let label: String
        let value: String
        let chips: [String]?
        let wide: Bool
        let style: Font
    }

    private var cells: [Cell] {
        let text = TopicText()
        return columns.compactMap { question in
            guard let value = entry.answers[question.key] else { return nil }
            if case .strings(let values) = value, case .choice(let rules) = question.kind {
                guard !values.isEmpty else { return nil }
                let labels = values.map { v in rules.options.first { $0.value == v }?.label ?? v }
                return Cell(
                    id: question.key, label: question.label, value: "", chips: labels, wide: true, style: .qr(.body))
            }
            guard let shown = text.answer(value, for: question) else { return nil }
            switch question.kind {
            case .string:
                return Cell(
                    id: question.key, label: question.label, value: shown, chips: nil, wide: true, style: .qr(.body))
            case .choice:
                return Cell(
                    id: question.key, label: question.label, value: shown, chips: nil, wide: oneColumn,
                    style: .qr(.label))
            case .int, .double:
                return Cell(
                    id: question.key, label: question.label, value: shown, chips: nil, wide: oneColumn,
                    style: .qr(.mono))
            }
        }
    }

    var body: some View {
        let cells = cells
        if !cells.isEmpty {
            LazyVGrid(
                columns: oneColumn ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading, spacing: 8
            ) {
                ForEach(cells) { cell in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.label).font(.qr(.caption)).foregroundStyle(.qr.muted)
                        if let chips = cell.chips {
                            FlowChips(labels: chips)
                        } else {
                            Text(cell.value)
                                .font(cell.style)
                                .foregroundStyle(.qr.ink)
                                .lineLimit(cell.wide ? 2 : nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Accent chips for a multi-select answer, wrapping.
private struct FlowChips: View {
    let labels: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    private var chips: some View {
        ForEach(labels, id: \.self) { QuickrBadge($0, tone: .accent) }
    }
}

/// The source (as the server has it), the channel (not for the web UI), and how long ago.
private struct EntryFooter: View {
    let entry: Entry

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
                QuickrBadge(entry.source)
                if let channel = Self.label(entry.channel) {
                    QuickrBadge(channel, tone: entry.channel == .ios ? .info : .neutral)
                }
                Spacer(minLength: 0)
                Text(TopicText().relative(entry.capturedAt, now: context.date))
                    .font(.qr(.caption))
                    .foregroundStyle(.qr.muted)
            }
        }
    }

    /// The PWA's `ChannelBadge`: nothing for the web UI.
    static func label(_ channel: Channel) -> String? {
        switch channel {
        case .ui: nil
        case .api: "API"
        case .mcp: "MCP"
        case .ios: "iOS"
        }
    }
}

private struct Message<Action: View>: View {
    let title: String
    let text: String
    let id: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
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

extension Message where Action == EmptyView {
    init(title: String, text: String, id: String) {
        self.init(title: title, text: text, id: id) { EmptyView() }
    }
}
