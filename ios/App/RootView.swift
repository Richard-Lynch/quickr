import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The navigation root: the home screen. LINKS fills `Route` and the destinations.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        content
            // One host for every screen's toasts, so a toast outlives navigation.
            .toastHost(environment.toasts)
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

    private var stack: some View {
        @Bindable var router = environment.router
        return NavigationStack(path: $router.path) {
            home
                .navigationDestination(for: Route.self, destination: destination(for:))
        }
    }

    private func destination(for route: Route) -> Never {
        switch route {}
    }

    @ViewBuilder private var home: some View {
        if let session = environment.session {
            HomeView(session: session)
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
