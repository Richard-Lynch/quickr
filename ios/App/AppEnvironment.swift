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
    let router = Router()
    /// Nil only when it couldn't be created (`sessionError`); `start()` tries again.
    private(set) var session: AppSession?
    private(set) var sessionError: String?
    private(set) var lastScenePhase: ScenePhase?

    @ObservationIgnored private let makeSession: @MainActor () throws -> AppSession
    @ObservationIgnored private var starting: Task<Void, Never>?

    init(settings: AppSettings, makeSession: @escaping @MainActor () throws -> AppSession) {
        self.settings = settings
        self.makeSession = makeSession
        openSession()
    }

    /// The live session over the App Group's files, sending through URLSession.
    static func live(location: StoreLocation = .shared(appGroup: AppGroup.identifier)) -> AppEnvironment {
        AppEnvironment(settings: AppSettings(defaults: AppGroup.defaults)) {
            // Cloudflare Access credentials come from the Keychain once SETTINGS adds them.
            try AppSession(configuration: .init(location: location, transport: URLSessionTransport()))
        }
    }

    /// The app's launch path: builds the live environment and registers the active store's topics
    /// for App Intents. Siri, Shortcuts and widget buttons can launch the app for an intent without
    /// a scene, so this runs in `QuickRApp.init`, before anything can query an entity. It opens
    /// the registry only; the store opens on first use.
    static func bootstrap(location: StoreLocation = .shared(appGroup: AppGroup.identifier)) -> AppEnvironment {
        let environment = live(location: location)
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
            await session?.start(serverURL: settings.serverURL)
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
            Task { await session.didBecomeActive() }
        case .background:
            flushInBackground(session)
        default:
            break
        }
    }

    private func flushInBackground(_ session: AppSession) {
        let task = BackgroundTask()
        // On expiry: cancel the flush and wait (briefly) for it and any pull to end before GRDB is
        // suspended; the task ends after that.
        task.begin(name: "quickr.flush") { await session.backgroundTimeExpiring() }
        Task {
            await session.didEnterBackground()
            task.end()
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
