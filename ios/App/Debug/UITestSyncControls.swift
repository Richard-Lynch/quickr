#if DEBUG
import QuickrCore
import QuickrData
import SwiftUI

/// `-QuickrUITest -QuickrSyncControls`: buttons the sync UI tests use to go offline and online
/// (the fake server and the network path together), log an entry and reject the next create.
struct UITestSyncControls: View {
    @Environment(AppEnvironment.self) private var environment
    /// The fake server's Mood topic.
    static let topic = TopicRef(id: FakeServer.moodId, slug: "mood", name: "Mood")

    var body: some View {
        HStack(spacing: 8) {
            control("Offline", "debug.offline") {
                UITestLaunch.server.offline = true
                UITestLaunch.network.set(online: false)
            }
            control("Online", "debug.online") {
                UITestLaunch.server.offline = false
                UITestLaunch.network.set(online: true)
            }
            control("Log", "debug.log") {
                _ = try? await environment.session?.log(
                    topic: Self.topic, answers: ["mood": .string("good")], version: 1)
            }
            control("Reject", "debug.reject") { UITestLaunch.server.rejectNextCreate() }
        }
        .font(.caption)
        .padding(6)
        .background(.thinMaterial, in: Capsule())
    }

    private func control(_ title: String, _ id: String, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .accessibilityIdentifier(id)
    }
}
#endif
