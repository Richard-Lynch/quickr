import QuickrCore
import SwiftUI

/// A topic's own pages, for the surfaces that show its run instead of its tile (active-surfaces.md
/// §3.2): the "Active now" card's "…" and the run screen's More menu. An open run never hides
/// the topic's stats, entries, builder or settings.
enum TopicPage: String, CaseIterable, Identifiable {
    case stats
    case entries
    case edit
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stats: "Stats"
        case .entries: "Entries"
        case .edit: "Edit questions"
        case .settings: "Topic settings"
        }
    }

    var systemImage: String {
        switch self {
        case .stats: "chart.bar"
        case .entries: "list.bullet"
        case .edit: "pencil"
        case .settings: "gearshape"
        }
    }

    /// The screen: the topic's Overview tab is its stats.
    func route(_ ref: TopicLinkRef) -> Route {
        switch self {
        case .stats: .topic(ref, .overview)
        case .entries: .topic(ref, .entries)
        case .edit: .editQuestions(ref)
        case .settings: .topicSettings(ref)
        }
    }
}

/// The menu items opening each `TopicPage`; their accessibility ids are `<prefix>.<page>`.
struct TopicPageItems: View {
    let ref: TopicLinkRef
    let prefix: String
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ForEach(TopicPage.allCases) { page in
            Button {
                environment.router.open(page.route(ref))
            } label: {
                Label(page.title, systemImage: page.systemImage)
            }
            .accessibilityIdentifier("\(prefix).\(page.id)")
        }
    }
}
