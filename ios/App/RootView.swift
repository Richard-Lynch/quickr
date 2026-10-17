import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// M0 placeholder: proves the app links QuickrCore, QuickrData and QuickrUI.
struct RootView: View {
    var body: some View {
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
