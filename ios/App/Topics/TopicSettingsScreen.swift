import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/t/:ref/settings`: finds the topic in the bound store, keeps it current while the screen is
/// open (a sync, an archive), and shows `TopicSettingsView`.
struct TopicSettingsScreen: View {
    let ref: TopicLinkRef
    @Environment(AppEnvironment.self) private var environment
    @State private var load = Load.loading

    private enum Load {
        case loading
        case ready(TopicSettingsModel, AppSession.Binding)
        case missing
        case failed(String)
    }

    /// How long a link waits for its topic to arrive (a first sync still loading it).
    static let topicWait: Duration = .seconds(10)

    var body: some View {
        content
            .task(id: environment.session?.binding) { if case .loading = load { await start() } }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .qrPaperBackground()
        case .ready(let model, let binding):
            TopicSettingsView(model: model)
                .task(id: binding) { await follow(model, in: binding) }
        case .missing:
            TopicNotice(title: "Topic settings", heading: "Topic not found", text: "It may have been deleted.")
        case .failed(let message):
            TopicNotice(title: "Topic settings", heading: "Couldn’t open this topic", text: message)
        }
    }

    private func start() async {
        guard let session = environment.session, let store = session.store, let binding = session.binding else {
            switch environment.session?.phase {
            case .noServer: load = .failed("Connect to a server first.")
            case .failed(let message): load = .failed(message)
            default: break  // still starting: wait for the binding
            }
            return
        }
        // A slug save replaced this screen's route: carry on with the same model (and any unsaved
        // edit in the other section) instead of starting over.
        if let model = TopicSettingsHandoff.take(ref: ref, binding: binding) {
            load = .ready(model, binding)
            return
        }
        do {
            guard
                let topic = try await TopicLookup.find(
                    ref, in: store, refresh: session.refresh.stream(), wait: Self.topicWait)
            else {
                load = .missing
                return
            }
            let router = environment.router
            let holder = TopicSettingsHandoff.Holder()
            let model = TopicSettingsModel(
                topic: topic, writer: SessionTopicWriter(session: session, binding: binding),
                toasts: environment.toasts,
                onSlugChanged: { slug in
                    guard let ref = TopicLinkRef(slug) else { return }
                    if let model = holder.model { TopicSettingsHandoff.put(model, binding: binding) }
                    router.replaceTop(with: .topicSettings(ref))
                },
                onDeleted: { router.path = [] })
            holder.model = model
            load = .ready(model, binding)
        } catch {
            load = .failed(String(describing: error))
        }
    }

    /// Feeds the store's copy of the topic to the model while the screen shows it.
    private func follow(_ model: TopicSettingsModel, in binding: AppSession.Binding) async {
        guard let session = environment.session, session.binding == binding, let store = session.store else { return }
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                if let current = topics.first(where: { $0.id == model.topic.id }) { model.topicChanged(current.topic) }
            }
        } catch {
            // The observation ends with the store (a switch or a reset); the screen stays as it is.
        }
    }
}

/// Finds a topic by id or slug in a store, waiting a while for a first sync to bring it.
enum TopicLookup {
    static func find(_ ref: TopicLinkRef, in store: LocalStore, refresh: AsyncStream<Void>, wait: Duration)
        async throws -> Topic?
    {
        if let topic = try await lookUp(ref, in: store) { return topic }
        return try await withThrowingTaskGroup(of: Topic?.self) { group in
            group.addTask {
                for try await topics in store.observeTopics(refresh: refresh) {
                    if let match = topics.first(where: { ref.matches($0.topic) }) { return match.topic }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: wait)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func lookUp(_ ref: TopicLinkRef, in store: LocalStore) async throws -> Topic? {
        if let id = ref.id { return try await store.topics.topic(id: id)?.topic }
        return try await store.topics.topic(slug: ref.rawValue)?.topic
    }
}

/// A screen that can't show its topic.
struct TopicNotice: View {
    let title: String
    let heading: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(heading).font(.qr(.title)).foregroundStyle(.qr.ink)
            Text(text).font(.qr(.subheadline)).foregroundStyle(.qr.muted).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qrPaperBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("topicNotice")
    }
}

/// Hands a settings model to the screen that replaces its route after a slug save (the route names
/// the slug, so it may be a new screen; SwiftUI usually keeps the old one, but that isn't a
/// guarantee). One-shot: taken by the next settings screen for the same topic in the same store,
/// and otherwise replaced by the next `put`.
@MainActor
enum TopicSettingsHandoff {
    final class Holder {
        weak var model: TopicSettingsModel?
    }

    static let shared = OneShotHandoff<TopicSettingsModel, AppSession.Binding>()

    static func put(_ model: TopicSettingsModel, binding: AppSession.Binding) {
        shared.put(model, scope: binding)
    }

    static func take(ref: TopicLinkRef, binding: AppSession.Binding) -> TopicSettingsModel? {
        shared.take(scope: binding) { ref.matches($0.topic) }
    }
}

/// One value passed from a screen to the one that replaces it, at most once.
@MainActor
final class OneShotHandoff<Value: AnyObject, Scope: Equatable> {
    private var pending: (value: Value, scope: Scope)?

    func put(_ value: Value, scope: Scope) {
        pending = (value, scope)
    }

    /// The value, if it was put for `scope` and `matches` it; it is gone afterwards.
    func take(scope: Scope, where matches: (Value) -> Bool) -> Value? {
        guard let pending, pending.scope == scope, matches(pending.value) else { return nil }
        self.pending = nil
        return pending.value
    }
}
