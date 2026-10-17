#if os(iOS)
import QuickrCore
import SwiftUI

/// Design system: brand tokens, fonts and shared components (M2a).
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
