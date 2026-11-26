#if DEBUG
import SwiftUI

/// `-QuickrUITest -QuickrClockControl`: "+16 min" moves the fake server's clock 16 minutes ahead
/// of the device's (`FakeServerState.clockAheadMs`), then this device pulls, so the next response's
/// `X-QuickR-Server-Time` moves the store's run clock (`server_offset_ms`, the latest sample wins)
/// past OQ-1's 15-minute Resume window (active-surfaces.md §3.3). `debug.clockAhead` shows the
/// minutes ahead once the pull returned. "Pull" syncs once (`debug.pull`; `debug.pulled` counts the
/// pulls that returned), so a test can wait until this device has applied what the server holds,
/// e.g. a stop's ack, before it goes offline.
struct UITestClockControl: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var ahead = 0
    @State private var pulls = 0

    static var isShown: Bool {
        UITestLaunch.isActive && ProcessInfo.processInfo.arguments.contains("-QuickrClockControl")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button("+16 min") {
                Task {
                    UITestLaunch.server.clockAheadMs += 16 * 60 * 1000
                    _ = await environment.session?.coordinator.sync(reason: .pullToRefresh)
                    ahead = UITestLaunch.server.clockAheadMs / 60_000
                }
            }
            .accessibilityIdentifier("debug.clockForward")
            Text("\(ahead) min").accessibilityLabel("\(ahead) min").accessibilityIdentifier("debug.clockAhead")
            Button("Pull") {
                Task {
                    _ = await environment.session?.coordinator.sync(reason: .pullToRefresh)
                    pulls += 1
                }
            }
            .accessibilityIdentifier("debug.pull")
            Text("pulled \(pulls)").accessibilityLabel("pulled \(pulls)").accessibilityIdentifier("debug.pulled")
        }
        .font(.caption)
        .padding(6)
        .background(.thinMaterial, in: Capsule())
    }
}
#endif
