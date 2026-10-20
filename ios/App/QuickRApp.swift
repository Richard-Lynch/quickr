import SwiftUI

@main
struct QuickRApp: App {
    @State private var environment: AppEnvironment
    #if DEBUG
    /// SPIKE: the notification action handler (App/Notifications/Spike), inert unless a spike run opted in (SpikeGate).
    @UIApplicationDelegateAdaptor(SpikeAppDelegate.self) private var spikeDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment.bootstrap()
        _environment = State(initialValue: environment)
        // Before launch ends, as BGTaskScheduler requires.
        BackgroundRefresh.register(environment)
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
