import QuickrCore
import QuickrUI
import SwiftUI

/// The screen for each `Route`. Settings, Record, New topic and Topic settings are built; the
/// other topic screens are placeholders that EDIT, BUILDER-UI and STATS replace.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .settings:
            SettingsView()
        case .newTopic:
            NewTopicScreen()
        case .topic(let ref, let tab):
            TopicTabsView(ref: ref, tab: tab)
        case .record(let ref, let fix):
            RecordScreen(ref: ref, fix: fix)
        case .entry(let ref, _):
            Pending(title: "Edit entry · \(ref)", route: route)
        case .editQuestions(let ref):
            Pending(title: "Edit questions · \(ref)", route: route)
        case .topicSettings(let ref):
            TopicSettingsScreen(ref: ref)
        }
    }
}

/// A screen that isn't built yet: names the route so links can be checked end to end.
struct Pending: View {
    let title: String
    let route: Route

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.qr(.title))
                .foregroundStyle(.qr.ink)
            Text(DeepLink.path(for: route))
                .font(.qr(.monoCaption))
                .foregroundStyle(.qr.muted)
                .accessibilityIdentifier("route.path")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qrPaperBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
