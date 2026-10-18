import SwiftUI

@main
struct QuickRApp: App {
    @State private var environment: AppEnvironment
    #if DEBUG
    /// SPIKE: the notification action handler (App/Notifications/Spike), inert without `-spikeServer`.
    @UIApplicationDelegateAdaptor(SpikeAppDelegate.self) private var spikeDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _environment = State(initialValue: AppEnvironment.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                #if DEBUG
            .overlay(alignment: .bottom) { SpikeStatusView() }
                #endif
                .task { await environment.start() }
        }
        .onChange(of: scenePhase) { _, phase in environment.scenePhaseChanged(phase) }
    }
}
