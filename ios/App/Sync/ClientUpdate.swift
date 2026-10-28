import Foundation
import Observation
import QuickrCore
import QuickrData

/// The active store's API-level state for the UI (client-versions.md §4.1, §4.5), from its
/// `sync_state`, which any process may write: the blocking "Update required" view while this build
/// is below the server's minimum, and the "server needs updating" note while the server is behind
/// this build. Lives in `AppEnvironment`; the root view runs `observe(_:)` per store binding.
@MainActor @Observable
final class ClientUpdate {
    /// Where Open TestFlight goes until the server names its own (`update_url.ios`, §3.2).
    static let defaultUpdateURL = URL(string: "itms-beta://")!
    /// The note of §3.3, on Home and in Settings ▸ Server.
    static let serverBehindMessage =
        "The quickR server is older than this app. It keeps working, but deploy the server to finish the update."

    /// `client_outdated_min` while it refuses this build; nil when it doesn't.
    private(set) var outdatedMinimum: Int?
    /// `server_api_level`: the latest response's `X-QuickR-Api-Level`.
    private(set) var serverApiLevel: Int?
    /// The server's `update_url.ios`, once Check again has read it.
    private(set) var updateURL = ClientUpdate.defaultUpdateURL
    /// A Check again is in flight.
    private(set) var checking = false
    /// The Home banner was dismissed: it stays away for this launch (Settings still says it).
    var serverNoteDismissed = false

    @ObservationIgnored private weak var session: AppSession?

    var isOutdated: Bool { outdatedMinimum != nil }
    var serverIsBehind: Bool { serverApiLevel.map { $0 < APILevel.current } ?? false }
    var showsServerBanner: Bool { serverIsBehind && !serverNoteDismissed && !isOutdated }

    /// "quickR needs an update…" with the count of changes waiting on this iPhone.
    static func message(unsynced: Int) -> String {
        "quickR needs an update to keep syncing with your server. Your unsynced changes (\(unsynced)) are safe on this iPhone."
    }

    /// Follows the bound store's `sync_state` until the task is cancelled (a new binding) or the
    /// store closes. The flag is per store, so another binding starts from its own.
    func observe(_ session: AppSession) async {
        self.session = session
        outdatedMinimum = nil
        serverApiLevel = nil
        guard let store = session.store else { return }
        do {
            for try await state in store.observeSyncState(refresh: session.refresh.stream()) {
                outdatedMinimum = state.flatMap { $0.isClientOutdated ? $0.clientOutdatedMin : nil }
                serverApiLevel = state?.serverApiLevel
            }
        } catch {
            // the store closed (reset, server switch): the next binding observes its own
        }
    }

    /// Check again (and every foreground while outdated): `getClientVersions`, which an outdated
    /// build still sends. Its response's levels go to the store like any other's, so a minimum this
    /// build meets clears the flag; then the held items are sent and the feed pulled.
    func checkAgain() async {
        guard !checking, let session, let store = session.store,
            let state = try? await store.syncState.syncState(), let baseURL = URL(string: state.baseURL)
        else { return }
        checking = true
        defer { checking = false }
        let wasOutdated = state.isClientOutdated
        let configuration = session.configuration
        let client = APIClient(
            baseURL: baseURL, transport: configuration.transport,
            identity: StaticServerIdentity(state.epoch.map { ServerIdentity(serverId: state.serverId, epoch: $0) }),
            credentials: configuration.credentials, origin: .app, serverOffset: StoreServerOffset(store: store),
            levels: StoreClientLevels(store: store))
        if case .success(let versions)? = try? await client.getClientVersions().outcome,
            let url = URL(string: versions.iosUpdateURL)
        {
            updateURL = url
        }
        guard wasOutdated, await StoreClientLevels(store: store).outdatedMinimum() == nil,
            session.store?.scope == store.scope
        else { return }
        await session.scheduler?.requestFlush(reason: .retry)
        Task { _ = await session.coordinator.sync(reason: .requested) }
    }

    /// `scenePhase` → `.active`: checks again while outdated (§4.1).
    func didBecomeActive() {
        guard isOutdated else { return }
        Task { await checkAgain() }
    }
}
