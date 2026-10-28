import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The navigation root: onboarding until a server is set up, then the `NavigationStack` of
/// `Route`s over the home screen. Links (`quickr://`, the server's
/// PWA URLs) open through the router.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Onboarding stays up from "no server" until it finishes (its reminders step comes after
    /// the connect has already made the session ready).
    @State private var onboarding = false
    /// "Update required", above every window and presentation (client-versions.md §4.1).
    @State private var updateWindow = UpdateRequiredWindow()

    var body: some View {
        content
            // One host for every screen's toasts, so a toast outlives navigation; a screen with a
            // sticky bar (Record's Save) raises them above it.
            .toastHost(environment.toasts, bottomInset: environment.toastBottomInset)
            // A server switch or a reset: the APNs token follows the bound store (REG).
            .onChange(of: environment.session?.binding) { _, _ in
                Task { await environment.push?.bindingChanged() }
            }
            .onChange(of: environment.clientUpdate.isOutdated, initial: true) { _, outdated in
                updateWindow.update(outdated: outdated, environment: environment)
            }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let page = Self.catalogPage {
            DesignCatalogView(page: page)
        } else if let gallery = Self.widgetGallery {
            WidgetGalleryView(page: gallery.page, tinted: gallery.tinted, outdated: gallery.outdated)
        } else if let demo = Self.formDemo {
            FormDemoView(demo: demo)
        } else if Self.snippetGallery {
            SnippetGalleryView()
        } else {
            stack
        }
        #else
        stack
        #endif
    }

    #if DEBUG
    /// `-QuickrDesignCatalog <colors|type|controls|tiles>` shows the design-system catalogue (screenshots).
    private static var catalogPage: DesignCatalogView.Page? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-QuickrDesignCatalog") else { return nil }
        let raw = i + 1 < args.count ? args[i + 1] : ""
        return DesignCatalogView.Page(rawValue: raw) ?? .colors
    }

    /// `-QuickrWidgetGallery <home|lock> [tinted] [outdated]` shows the widget views (screenshots,
    /// UI checks).
    private static var widgetGallery: (page: WidgetGalleryView.Page, tinted: Bool, outdated: Bool)? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-QuickrWidgetGallery") else { return nil }
        let raw = i + 1 < args.count ? args[i + 1] : ""
        return (WidgetGalleryView.Page(rawValue: raw) ?? .home, args.contains("tinted"), args.contains("outdated"))
    }

    /// `-QuickrSnippetGallery` shows the Siri confirmation snippet over demo drafts (screenshots).
    private static var snippetGallery: Bool { ProcessInfo.processInfo.arguments.contains("-QuickrSnippetGallery") }

    /// `-QuickrFormDemo <workout|types|fix>` shows the answer form over a fixed topic (UI tests).
    private static var formDemo: FormDemoView.Demo? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-QuickrFormDemo") else { return nil }
        let raw = i + 1 < args.count ? args[i + 1] : ""
        return FormDemoView.Demo(rawValue: raw) ?? .workout
    }
    #endif

    @ViewBuilder
    private var stack: some View {
        if onboarding, let session = environment.session {
            OnboardingView(session: session, settings: environment.settings, credentials: environment.credentials) {
                onboarding = false
            }
        } else {
            navigation
                .onOpenURL { url in environment.open(url: url) }
                #if DEBUG
            .task {
                await UITestLaunch.prepare(environment)
                if let url = UITestLaunch.openURL { environment.open(url: url) }
                await DemoNotify.schedule(environment)
            }
                #endif
                .onChange(of: needsServer, initial: true) { _, needed in
                    if needed { onboarding = true }
                }
        }
    }

    private var navigation: some View {
        @Bindable var router = environment.router
        return NavigationStack(path: $router.path) {
            home
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
        .syncSheet(environment)
        // The sync pill and sheet follow the active store (SYNC-UX).
        .task(id: environment.session?.binding) {
            if let session = environment.session { await environment.sync.observe(session) }
        }
        // So does "Update required" (client-versions.md §4.1, §4.5).
        .task(id: environment.session?.binding) {
            if let session = environment.session {
                await environment.clientUpdate.observe(session)
            } else {
                environment.clientUpdate.reset()
            }
        }
        // The run clocks' server offset (timers.md §5.1).
        .task(id: environment.session?.binding) {
            if let session = environment.session { await environment.runTicker.observe(session) }
        }
        // The run notices too (timers.md §11.4).
        .task(id: environment.session?.binding) {
            if let session = environment.session { await environment.runNotices.observe(session) }
        }
        // The Live Activities are reconciled with the active store's runs (timers.md §10.3).
        .task(id: environment.session?.binding) { await environment.observeRunsForLiveActivities() }
        // The widgets follow the active store too.
        .task(id: environment.session?.binding) {
            if let session = environment.session, let store = session.store {
                await environment.widgets.observe(store, refresh: { session.refresh.stream() })
            }
        }
        #if DEBUG
        .overlay(alignment: .bottom) {
            // While "Update required" is up, its window has the controls.
            if UITestLaunch.showsSyncControls, !environment.clientUpdate.isOutdated {
                UITestSyncControls().padding(.bottom, 24)
            }
        }
        #endif
        #if DEBUG || QUICKR_PERF
        .overlay(alignment: .topTrailing) {
            if PerfStore.isRequested {
                Text(verbatim: PerfProbe.shared.firstRender.map(String.init) ?? "-")
                .font(.caption2).monospacedDigit()
                .accessibilityIdentifier("perf.firstRender")
            }
        }
        #endif
        .alert(
            "Can’t open that link", isPresented: unopenedLink,
            actions: { Button("OK", role: .cancel) {} },
            message: { Text("It isn’t a quickR page.") }
        )
        .alert(
            "Can’t open that here", isPresented: refusedLink,
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(environment.router.refusedLink ?? "") })
    }

    /// No server, once the launch's start has settled (not the `.noServer` it passes through
    /// while connecting to a configured address).
    private var needsServer: Bool {
        environment.hasStarted && environment.session?.phase == .noServer
    }

    private var refusedLink: Binding<Bool> {
        Binding(
            get: { environment.router.refusedLink != nil },
            set: { if !$0 { environment.router.refusedLink = nil } })
    }

    private var unopenedLink: Binding<Bool> {
        Binding(
            get: { environment.router.unopenedLink != nil },
            set: { if !$0 { environment.router.unopenedLink = nil } })
    }

    /// Where the home screen's buttons go.
    private var homeActions: HomeActions {
        let router = environment.router
        func ref(_ topic: ViewTopic) -> TopicLinkRef {
            TopicLinkRef(topic.topic.slug) ?? TopicLinkRef(id: topic.topic.id)
        }
        return HomeActions(
            open: { router.open(.topic(ref($0), .overview)) },
            record: { router.open(.record(ref($0))) },
            newTopic: { router.open(.newTopic) },
            settings: { router.open(.settings) },
            onboarding: { onboarding = true })
    }

    @ViewBuilder private var home: some View {
        if let session = environment.session {
            HomeView(session: session, actions: homeActions)
        } else {
            // The session couldn't be created (the store's files); `start()` tries again.
            VStack(spacing: 8) {
                Text("quickR")
                    .font(.qr(.largeTitle))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("root.title")
                Text("Store failed: \(environment.sessionError ?? "unknown error")")
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("root.storeStatus")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .qrPaperBackground()
        }
    }
}

#Preview {
    RootView()
        .environment(
            AppEnvironment.live(
                location: StoreLocation(root: URL.temporaryDirectory.appending(path: "preview")), categoryCenter: nil))
}
