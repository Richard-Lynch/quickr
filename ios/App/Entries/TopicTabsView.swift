import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A topic's tabs (the PWA's `TopicLayout`): Overview, Entries and Versions (LIST's, STATS's and
/// BUILDER-UI's), with Edit questions and the topic's settings in the toolbar. Switching tabs swaps
/// the route in place, so a link or Back lands on the same tab. Above the tabs, the topic's header
/// (appearance.md §6.3) when it has an appearance.
struct TopicTabsView: View {
    let ref: TopicLinkRef
    let tab: TopicTab
    @Environment(AppEnvironment.self) private var environment
    /// For the header; by id once found, as a slug can change.
    @State private var topic: ViewTopic?

    var body: some View {
        VStack(spacing: 0) {
            // Nothing until the topic resolves, and nothing for a topic without an appearance (§4.3).
            if let topic, let header = TopicHeaderContent.make(for: topic.topic) {
                TopicHeaderView(header)
            }
            // Segments, or a menu at accessibility sizes, where segments stop growing (a11y B1).
            QuickrSegmentedPicker("Tab", selection: tabBinding, valueLabel: tab.rawValue.capitalized) {
                ForEach(TopicTab.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("topic.tabs")
            switch tab {
            case .entries:
                if let session = environment.session {
                    EntriesView(session: session, ref: ref)
                } else {
                    Pending(title: "\(ref) · Entries", route: .topic(ref, .entries))
                }
            case .overview:
                if let session = environment.session {
                    OverviewView(session: session, ref: ref)
                } else {
                    Pending(title: "\(ref) · Overview", route: .topic(ref, .overview))
                }
            case .versions:
                if let session = environment.session {
                    VersionsView(session: session, ref: ref)
                } else {
                    Pending(title: "\(ref) · Versions", route: .topic(ref, tab))
                }
            }
        }
        .qrPaperBackground()
        .task(id: environment.session?.binding) { await observeTopic() }
        .navigationTitle(ref.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.open(.editQuestions(ref))
                } label: {
                    Label("Edit questions", systemImage: "pencil")
                }
                .accessibilityIdentifier("topic.editQuestions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.open(.topicSettings(ref))
                } label: {
                    Label("Topic settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("topic.settings")
            }
        }
    }

    private var tabBinding: Binding<TopicTab> {
        Binding(get: { tab }, set: { environment.router.replaceTop(with: .topic(ref, $0)) })
    }

    private func observeTopic() async {
        topic = nil
        guard let session = environment.session, let store = session.store else { return }
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                topic = topics.first { candidate in
                    topic.map { candidate.topic.id == $0.topic.id } ?? candidate.matches(ref: ref.rawValue)
                }
            }
        } catch {
            // The tab below reports a store failure; the header stays away.
        }
    }
}
