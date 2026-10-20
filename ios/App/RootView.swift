import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The navigation root. LINKS fills `Route` and the destinations; the home screen replaces
/// `placeholder` in M2.
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
        } else if ProcessInfo.processInfo.arguments.contains("-QuickrTilesDemo") {
            TilesDemoView()
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
            placeholder
                .navigationDestination(for: Route.self, destination: destination(for:))
        }
    }

    private func destination(for route: Route) -> Never {
        switch route {}
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Text("quickR")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("root.title")
            QuickrUI.VersionLabel()
                .accessibilityIdentifier("root.coreVersion")
            Text("Data → Core \(QuickrData.coreVersion)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text(storeStatus)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("root.storeStatus")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var storeStatus: String {
        if let error = environment.sessionError { return "Store failed: \(error)" }
        switch environment.session?.phase {
        case .ready: return "Store ready"
        case .noServer: return "No server yet"
        case .failed(let error): return "Store failed: \(error)"
        case .starting, nil: return "Store opening…"
        }
    }
}

#Preview {
    RootView()
        .environment(
            AppEnvironment.live(location: StoreLocation(root: URL.temporaryDirectory.appending(path: "preview"))))
}
