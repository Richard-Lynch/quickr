import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// M0 placeholder: proves the app links QuickrCore, QuickrData and QuickrUI.
struct RootView: View {
    var body: some View {
        #if DEBUG
        if let page = Self.catalogPage {
            DesignCatalogView(page: page)
        } else {
            placeholder
        }
        #else
        placeholder
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
    #endif

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    RootView()
}
