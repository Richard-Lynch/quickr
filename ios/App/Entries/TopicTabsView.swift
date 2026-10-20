import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A topic's tabs (the PWA's `TopicLayout`): Overview, Entries and Versions. Entries is LIST's,
/// Overview STATS's; Versions is a placeholder until its package lands. Switching tabs swaps the route in
/// place, so a link or Back lands on the same tab.
struct TopicTabsView: View {
    let ref: TopicLinkRef
    let tab: TopicTab
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: tabBinding) {
                ForEach(TopicTab.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
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
                Pending(title: "\(ref) · Versions", route: .topic(ref, tab))
            }
        }
        .qrPaperBackground()
        .navigationTitle(ref.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tabBinding: Binding<TopicTab> {
        Binding(get: { tab }, set: { environment.router.replaceTop(with: .topic(ref, $0)) })
    }
}
