import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A topic's tabs (the PWA's `TopicLayout`): Overview, Entries and Versions (LIST's, STATS's and
/// BUILDER-UI's), with Edit questions and the topic's settings in the toolbar. Switching tabs swaps
/// the route in place, so a link or Back lands on the same tab.
struct TopicTabsView: View {
    let ref: TopicLinkRef
    let tab: TopicTab
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            // Segments, or a menu at accessibility sizes, where segments stop growing (a11y B1).
            QuickrSegmentedPicker("Tab", selection: tabBinding) {
                ForEach(TopicTab.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The menu's button names the tab it is on (VoiceOver, and UI tests at AX sizes).
            .accessibilityValue(tab.rawValue.capitalized)
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
}
