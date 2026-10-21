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
        #if DEBUG || QUICKR_PERF
        PerfProbe.mark("App.init")
        #endif
        #if DEBUG
        let environment =
            DemoStore.isRequested
            ? DemoStore.environment() : PerfStore.isRequested ? PerfStore.environment() : AppEnvironment.bootstrap()
        #elseif QUICKR_PERF
        let environment = PerfStore.isRequested ? PerfStore.environment() : AppEnvironment.bootstrap()
        #else
        let environment = AppEnvironment.bootstrap()
        #endif
        _environment = State(initialValue: environment)
        // The VoiceOver magic tap runs a toast's Undo (AppDelegate).
        AppDelegate.toasts = environment.toasts
        // Before the app delegate's `didFinishLaunching` makes the responder the center's delegate.
        NotificationResponder.shared.attach(environment)
        // Before launch ends, as BGTaskScheduler requires.
        BackgroundRefresh.register(environment)
        #if DEBUG || QUICKR_PERF
        PerfProbe.mark("App.init done (environment, session open)")
        #endif
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
