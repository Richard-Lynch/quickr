import QuickrData
import SwiftUI

@main
struct QuickRApp: App {
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment.live()
        // Siri, Shortcuts and widget buttons can launch the app for an intent without a scene, so
        // the intents' topic source is registered here, before anything can query it.
        IntentTopicSource.register(environment.topics)
        _environment = State(initialValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task { await environment.start() }
        }
        .onChange(of: scenePhase) { _, phase in environment.scenePhaseChanged(phase) }
    }
}
