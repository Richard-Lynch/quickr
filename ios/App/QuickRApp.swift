import SwiftUI

@main
struct QuickRApp: App {
    @State private var environment: AppEnvironment
    #if DEBUG
    /// SPIKE: the notification action handler (App/Notifications/Spike), inert unless a spike run opted in (SpikeGate).
    /// It subclasses `AppDelegate`, so REG's token callbacks work in DEBUG too.
    @UIApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate
    #else
    /// The APNs token callbacks (REG).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if DemoStore.isRequested {
            _environment = State(initialValue: DemoStore.environment())
            return
        }
        #endif
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
