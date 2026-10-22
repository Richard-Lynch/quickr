#if os(iOS)
import QuickrCore
import SwiftUI

/// Design system: brand tokens (`Color.qr`, `Font.qr`, `QuickrMetrics`), icons (`QIcon`) and
/// components. `DesignCatalogView` shows them all.
public enum QuickrUI {
    /// A small caption showing the Core version, used by the M0 root view.
    public struct VersionLabel: View {
        public init() {}

        public var body: some View {
            Text("Core \(QuickrCore.version)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
#endif
