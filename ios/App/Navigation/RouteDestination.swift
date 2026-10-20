import QuickrCore
import QuickrUI
import SwiftUI

/// The screen for each `Route`. Settings is SETTINGS's; the topic screens are placeholders that
/// HOME, RECORD, EDIT, BUILDER, STATS and the topic settings package replace as they land.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .settings:
            SettingsView()
        case .newTopic:
            Pending(title: "New topic", route: route)
        case .topic(let ref, let tab):
            Pending(title: "\(ref) · \(tab.rawValue.capitalized)", route: route)
        case .record(let ref, let fix):
            Pending(title: fix == nil ? "Record · \(ref)" : "Fix entry · \(ref)", route: route)
        case .entry(let ref, _):
            Pending(title: "Edit entry · \(ref)", route: route)
        case .editQuestions(let ref):
            Pending(title: "Edit questions · \(ref)", route: route)
        case .topicSettings(let ref):
            Pending(title: "Topic settings · \(ref)", route: route)
        }
    }
}

/// A screen that isn't built yet: names the route so links can be checked end to end.
private struct Pending: View {
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
