import Foundation
import Observation
import QuickrData
import SwiftUI
import UIKit

/// The app's services, built once in `QuickRApp.init` and injected with `.environment(_:)`. The
/// composition root is `session` (QuickrData's `AppSession`): store, sync, outbox and the write
/// façade. This type adds what needs UIKit or SwiftUI: settings, navigation, and the scene-phase
/// hooks with their background task.
@MainActor @Observable
final class AppEnvironment {
    let settings: AppSettings
    /// The Cloudflare Access tokens in the Keychain, one per server; the session reads the target
    /// server's on every request.
    let credentials: KeychainAccessCredentials?
    /// A Keychain problem from launch (the legacy token's migration), for Settings to show.
    private(set) var credentialsIssue: String?
    let router = Router()
    /// The sync pill and sheet's state, and the network and timer flush triggers (SYNC-UX).
    let sync: SyncController
    /// Nil only when it couldn't be created (`sessionError`); `start()` tries again.
    private(set) var session: AppSession?
    private(set) var sessionError: String?
    private(set) var lastScenePhase: ScenePhase?
    /// `start()` has finished once: the session has connected to the configured server, or
    /// found there is none. Onboarding waits for it (the session passes `.noServer` on the way).
    private(set) var hasStarted = false

    @ObservationIgnored private let makeSession: @MainActor () throws -> AppSession
    @ObservationIgnored private var starting: Task<Void, Never>?

    init(
        settings: AppSettings, credentials: KeychainAccessCredentials? = nil,
        network: any NetworkMonitoring = NWNetworkMonitor(),
        makeSession: @escaping @MainActor () throws -> AppSession
    ) {
        self.settings = settings
        self.credentials = credentials
        self.sync = SyncController(network: network)
        self.makeSession = makeSession
        openSession()
    }

    /// The live session over the App Group's files, sending through URLSession with the
    /// Cloudflare Access token from the shared Keychain.
    static func live(
        location: StoreLocation = .shared(appGroup: AppGroup.identifier), defaults: UserDefaults = AppGroup.defaults,
        keychain: any KeychainStore = SystemKeychain(), transport: any Transport = URLSessionTransport(),
        network: any NetworkMonitoring = NWNetworkMonitor()
    ) -> AppEnvironment {
        let credentials = KeychainAccessCredentials(keychain: keychain)
        return AppEnvironment(settings: AppSettings(defaults: defaults), credentials: credentials, network: network) {
            let session = try AppSession(
                configuration: .init(location: location, transport: transport, credentials: credentials))
            // Addresses resolve to servers through the registry, so each request gets its server's token.
            credentials.directory.attach(session.partitions.registry.repository)
            return session
        }
    }

    /// The app's launch path: builds the live environment and registers the active store's topics
    /// for App Intents. Siri, Shortcuts and widget buttons can launch the app for an intent without
    /// a scene, so this runs in `QuickRApp.init`, before anything can query an entity. It opens
    /// the registry only; the store opens on first use.
    static func bootstrap(location: StoreLocation = .shared(appGroup: AppGroup.identifier)) -> AppEnvironment {
        #if DEBUG
        let environment = UITestLaunch.isActive ? UITestLaunch.environment() : live(location: location)
        #else
        let environment = live(location: location)
        #endif
        environment.registerIntentTopics()
        return environment
    }

    /// What the App Intents queries and the screens read topics from: the active store's.
    var topics: any TopicRepository { session?.topics ?? NoTopicRepository() }

    func registerIntentTopics() {
        IntentTopicSource.register(topics)
    }

    /// From the root view's `.task`: starts the session (finishing a bootstrap, or connecting to
    /// the configured server) and refreshes the App Shortcuts' topic parameters. A launch for an
    /// intent alone (no scene) never runs it. Concurrent callers share one attempt.
    func start() async {
        if let starting {
            await starting.value
            return
        }
        let attempt = Task {
            if session == nil {
                openSession()
                registerIntentTopics()
            }
            // Before the first request, so it already carries the migrated token.
            await migrateLegacyToken()
            await session?.start(serverURL: settings.serverURL)
            if let session { sync.startMonitoring(session) }
            hasStarted = true
            QuickRShortcuts.updateAppShortcutParameters()
        }
        starting = attempt
        await attempt.value
        starting = nil
    }

    /// The `scenePhase` hooks (outbox.md §10, sync-protocol.md §9): on `.active`, resume, rebind,
    /// flush and pull; on `.background`, flush inside a background task whose expiration handler
    /// cancels the flush, then suspend the database (0xDEAD10CC).
    func scenePhaseChanged(_ phase: ScenePhase) {
        lastScenePhase = phase
        guard let session else { return }
        switch phase {
        case .active:
            sync.didBecomeActive()
            Task { await session.didBecomeActive() }
        case .background:
            sync.didEnterBackground()
            BackgroundRefresh.schedule()
            flushInBackground(session)
        default:
            break
        }
    }

    /// A `BGAppRefreshTask` (or the debug stand-in): pull, then send, as a background episode of
    /// its own; the expiration handler cancels and suspends (`backgroundTimeExpiring`). The next
    /// refresh is scheduled first. If the app is in the foreground it has nothing to do.
    func backgroundRefresh(_ task: any BackgroundRefreshTask) async {
        BackgroundRefresh.schedule()
        guard lastScenePhase != .active else {
            task.complete(success: true)
            return
        }
        await start()
        guard let session else {
            task.complete(success: false)
            return
        }
        let episode = session.beginBackground()
        task.onExpiration {
            Task { @MainActor in
                await session.backgroundTimeExpiring(episode, within: .seconds(2))
                task.complete(success: false)
            }
        }
        let result = await session.backgroundRefresh(episode)
        task.complete(success: result == .synced)
    }

    private func flushInBackground(_ session: AppSession) {
        // The episode is taken before the expiration handler is registered, so this task's
        // callbacks only ever act on their own trip to the background.
        let episode = session.beginBackground()
        let task = BackgroundTask()
        // On expiry: cancel the flush and wait (briefly) for it and any pull to end before GRDB is
        // suspended; the task ends after that.
        task.begin(name: "quickr.flush") { await session.backgroundTimeExpiring(episode) }
        Task {
            await session.didEnterBackground(episode)
            task.end()
        }
    }

    /// The first SETTINGS build kept one token for every server: it becomes the active server's
    /// (the registry's active one, or the configured address before any store exists).
    private func migrateLegacyToken() async {
        guard let credentials, let session else { return }
        do {
            let active = try await session.partitions.registry.repository.activeServerId()
            try credentials.migrateLegacy(serverId: active, baseURL: settings.serverURL)
        } catch {
            credentialsIssue = "Couldn’t move the Cloudflare Access token to this server’s: \(error)"
        }
    }

    private func openSession() {
        do {
            session = try makeSession()
            sessionError = nil
        } catch {
            sessionError = String(describing: error)
        }
    }
}

/// One `beginBackgroundTask`, ended once: by the work, or after the expiration handler's
/// `expiring` has finished.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(name: String, expiring: @escaping @MainActor () async -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                await expiring()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
