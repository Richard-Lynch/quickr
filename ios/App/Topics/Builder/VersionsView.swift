import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A topic's Versions tab (the PWA's `VersionsPage`): what versions are, "New version", and a
/// timeline of versions from the store, newest first; each one opens to its questions, the
/// current one open from the start.
struct VersionsView: View {
    let session: AppSession
    let ref: TopicLinkRef
    @Environment(AppEnvironment.self) private var environment
    @State private var topic: ViewTopic?
    @State private var resolved = false
    @State private var versions: [TopicVersion]?
    /// The rows opened or closed by hand; the others follow "current is open".
    @State private var toggled: Set<Int> = []

    private struct VersionsKey: Hashable {
        var topicId: UUID?
        var binding: AppSession.Binding?
    }

    var body: some View {
        List {
            Section {
                // Rows of their own, so neither is squeezed at accessibility sizes (BD6).
                Text(VersionsList.intro).font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                Button {
                    environment.router.open(.editQuestions(ref))
                } label: {
                    Label("New version", systemImage: "pencil").font(.qr(.label))
                }
                .accessibilityIdentifier("versions.new")
            }
            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .qrPaperBackground()
        .accessibilityIdentifier("versions.list")
        .task(id: session.binding) { await observeTopic() }
        .task(id: VersionsKey(topicId: topic?.topic.id, binding: session.binding)) { await observeVersions() }
    }

    @ViewBuilder
    private var content: some View {
        if let topic, let versions {
            let list = VersionsList(versions: versions, currentVersion: topic.topic.currentVersion)
            if let pending = list.pending {
                Section {
                    HStack(spacing: 10) {
                        QuickrBadge("v\(pending)", tone: .accent)
                        Text("Syncing…").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                        Spacer()
                        ProgressView()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("versions.pending")
                }
            }
            ForEach(list.rows) { row in
                VersionSection(row: row, isOpen: isOpen(row)) { toggle(row) }
            }
        } else if resolved && topic == nil {
            Section {
                Text("Topic not found. It may have been deleted.").foregroundStyle(.qr.muted)
            }
            .accessibilityIdentifier("versions.missing")
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        }
    }

    private func isOpen(_ row: VersionsList.Row) -> Bool { row.isCurrent != toggled.contains(row.version) }

    private func toggle(_ row: VersionsList.Row) {
        if toggled.remove(row.version) == nil { toggled.insert(row.version) }
    }

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
                topic = topics.first { candidate in
                    topic.map { candidate.topic.id == $0.topic.id } ?? candidate.matches(ref: ref.rawValue)
                }
                resolved = true
            }
        } catch {
            resolved = true
        }
    }

    private func observeVersions() async {
        versions = nil
        guard let id = topic?.topic.id, let store = session.store else { return }
        do {
            for try await all in store.observeVersions(topicId: id, refresh: session.refresh.stream()) {
                versions = all
            }
        } catch {
            // The observation ends with the store (a switch or a reset).
        }
    }
}

/// One version: its tag, "current", when, how many entries, its change note; open, its
/// questions (`QuestionSummaryList`).
private struct VersionSection: View {
    let row: VersionsList.Row
    let isOpen: Bool
    let toggle: () -> Void
    @QuickrReduceMotion private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Section {
            Button(action: { withQRAnimation(reduceMotion: reduceMotion) { toggle() } }) {
                VStack(alignment: .leading, spacing: 6) {
                    // The date and count get lines of their own at accessibility sizes (BD6).
                    if typeSize.isAccessibilitySize {
                        HStack(spacing: 8) {
                            tags
                            Spacer(minLength: 4)
                            chevron
                        }
                        date
                        entries
                    } else {
                        HStack(spacing: 8) {
                            tags
                            date
                            Spacer(minLength: 4)
                            entries
                            chevron
                        }
                    }
                    if let note = row.note {
                        Text(note).font(.qr(.body)).foregroundStyle(.qr.ink)
                    } else {
                        Text(row.placeholder).font(.qr(.body)).italic().foregroundStyle(.qr.muted)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("versions.v\(row.version)")
            if isOpen {
                ForEach(Array(row.questions.enumerated()), id: \.offset) { index, question in
                    QuestionSummaryRow(index: index, question: question)
                }
            }
        }
    }

    @ViewBuilder private var tags: some View {
        QuickrBadge("v\(row.version)")
        if row.isCurrent { QuickrBadge("current", tone: .accent) }
    }

    private var date: some View {
        Text(row.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.qr(.footnote))
            .foregroundStyle(.qr.muted)
    }

    private var entries: some View {
        Text(row.entries()).font(.qr(.monoCaption)).foregroundStyle(.qr.inkSoft)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.qr.muted)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
            .accessibilityHidden(true)
    }
}

/// A published question in a version (`QuestionSummaryList`'s row): number, label ("optional"),
/// key and constraints, a choice's options (archived ones struck through), and its type.
private struct QuestionSummaryRow: View {
    let index: Int
    let question: Question

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)").font(.qr(.monoCaption)).foregroundStyle(.qr.muted).frame(minWidth: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(question.label).font(.qr(.label)).foregroundStyle(.qr.ink)
                    if !question.required { Text("optional").font(.qr(.caption)).foregroundStyle(.qr.muted) }
                }
                Text("\(question.key) · \(QuestionSummary.constraint(question))")
                    .font(.qr(.monoCaption))
                    .foregroundStyle(.qr.muted)
                if case .choice(let rules) = question.kind {
                    FlowRow(options: rules.options)
                }
            }
            Spacer(minLength: 4)
            QuickrBadge(question.type.builderShort, tone: .info)
                // "Whole number", not "Int" (BD7).
                .accessibilityLabel(question.type.builderLabel)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A choice's options as badges, wrapping.
private struct FlowRow: View {
    let options: [EnumOption]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { badges }
            VStack(alignment: .leading, spacing: 4) { badges }
        }
    }

    @ViewBuilder private var badges: some View {
        ForEach(options, id: \.value) { option in
            Text(option.label)
                .strikethrough(option.archived)
                .font(.qr(.caption))
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .foregroundStyle(option.archived ? Color.qr.warn : .qr.inkSoft)
                .background(option.archived ? Color.qr.warnSoft : .qr.sunken, in: Capsule())
                .accessibilityLabel(option.archived ? "\(option.label), archived" : option.label)
        }
    }
}
