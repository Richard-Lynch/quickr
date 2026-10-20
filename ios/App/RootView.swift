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

    var body: some View {
        content
            // One host for every screen's toasts, so a toast outlives navigation; a screen with a
            // sticky bar (Record's Save) raises them above it.
            .toastHost(environment.toasts, bottomInset: environment.toastBottomInset)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if let page = Self.catalogPage {
            DesignCatalogView(page: page)
        } else if let demo = Self.formDemo {
            FormDemoView(demo: demo)
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
                .onOpenURL { url in environment.router.handle(url: url, serverURL: environment.settings.serverURL) }
                #if DEBUG
            .task {
                await UITestLaunch.prepare(environment)
                if let url = UITestLaunch.openURL {
                    environment.router.handle(url: url, serverURL: environment.settings.serverURL)
                }
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
        .alert(
            "Can’t open that link", isPresented: unopenedLink,
            actions: { Button("OK", role: .cancel) {} },
            message: { Text("It isn’t a quickR page.") })
    }

    /// No server, once the launch's start has settled (not the `.noServer` it passes through
    /// while connecting to a configured address).
    private var needsServer: Bool {
        environment.hasStarted && environment.session?.phase == .noServer
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
            onboarding: { onboarding = true },
            sync: {})  // SYNC-UX's sheet
    }

    @ViewBuilder private var home: some View {
        if let session = environment.session {
            HomeView(session: session, actions: homeActions)
        } else {
            // The session couldn't be created (the store's files); `start()` tries again.
            VStack(spacing: 8) {
                Text("quickR")
                    .font(.qr(.largeTitle))
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
            AppEnvironment.live(location: StoreLocation(root: URL.temporaryDirectory.appending(path: "preview"))))
}
