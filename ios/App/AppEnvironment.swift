import Foundation
import Observation
import QuickrData
import SwiftUI

/// The app's services, built once in `QuickRApp.init` and injected with `.environment(_:)`.
/// SKEL wires the shape; STORE, SYNC, OUTBOX and SETTINGS replace the stand-ins at integration.
@MainActor @Observable
final class AppEnvironment {
    let settings: AppSettings
    let router = Router()
    /// What the App Intents queries and the screens read topics from. SKEL: the placeholder list;
    /// STORE: the active server's `GRDBTopicRepository`.
    let topics: any TopicRepository
    /// Nil until `start()` has opened it, or when opening failed (`storeError`).
    private(set) var store: StoreHandle?
    private(set) var storeError: String?
    /// SYNC and OUTBOX plug in here.
    var sync: (any SyncEngineService)?
    var outbox: (any OutboxEngineService)?
    private(set) var lastScenePhase: ScenePhase?

    init(settings: AppSettings, topics: any TopicRepository) {
        self.settings = settings
        self.topics = topics
    }

    static func live() -> AppEnvironment {
        AppEnvironment(settings: AppSettings(defaults: AppGroup.defaults), topics: PlaceholderTopicRepository())
    }

    /// The app's launch path: builds the live environment and registers its topics for App Intents.
    /// Siri, Shortcuts and widget buttons can launch the app for an intent without a scene, so this
    /// runs in `QuickRApp.init`, before anything can query an entity.
    static func bootstrap() -> AppEnvironment {
        let environment = live()
        IntentTopicSource.register(environment.topics)
        return environment
    }

    /// Opens the store off the main actor and refreshes the App Shortcuts' topic parameters. Runs
    /// from the root view's `.task`, so a launch for an intent alone (no scene) never opens it.
    /// Concurrent callers share one attempt; a call after a failure tries again.
    func start() async {
        if let starting {
            await starting.value
            return
        }
        guard store == nil else { return }
        let attempt = Task { await openStore() }
        starting = attempt
        await attempt.value
        starting = nil
    }

    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private(set) var storeOpenAttempts = 0

    private func openStore() async {
        storeOpenAttempts += 1
        do {
            let url = AppGroup.storeDirectory.appendingPathComponent("skel.sqlite")
            store = try await Task.detached { try StoreHandle.open(at: url) }.value
            storeError = nil
        } catch {
            storeError = String(describing: error)
        }
        QuickRShortcuts.updateAppShortcutParameters()
    }

    /// The `scenePhase` hooks. SYNC: pull and flush on `.active`; schedule the background refresh
    /// on `.background`. SKEL only records the phase.
    func scenePhaseChanged(_ phase: ScenePhase) {
        lastScenePhase = phase
    }
}

/// SKEL's store: the C1 `StoreDatabase.openPool` and its repositories. STORE replaces it with the
/// registry and per-server partitions (`StorePartitions.openStore`).
struct StoreHandle: Sendable {
    let syncState: any SyncStateRepository

    static func open(at url: URL) throws -> StoreHandle {
        let pool = try StoreDatabase.openPool(at: url)
        return StoreHandle(syncState: GRDBSyncStateRepository(reader: pool))
    }
}

/// Filled in by SYNC.
protocol SyncEngineService: Sendable {}
/// Filled in by OUTBOX.
protocol OutboxEngineService: Sendable {}
