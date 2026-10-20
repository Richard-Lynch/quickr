import Foundation
import OSLog

/// The widget extension's `IntentWriteContext` (INTENTS' write contract): a widget chip or ✓, or a
/// Control, commits through `IntentLogging` to the **writable** active store (origin `.widget`,
/// source "ios.widget"), which is durable before `perform()` returns; then the widgets reload (the
/// topic shows "queued" at once) and one bounded flush sends it (`extensionFlush`, PLAN §2), then
/// they reload again. Offline, or out of time, the entry stays queued and the app or the next
/// trigger sends it; the app hears of the commit through `db-changed` (Darwin notifications).
public enum WidgetWrites {
    /// Inside the time a widget button gets (outbox.md §10: a 4 s extension budget).
    public static let flushBudget: Duration = .seconds(4)

    public static func context(
        location: StoreLocation, transport: any Transport = URLSessionTransport(),
        credentials: any AccessCredentialsProvider = KeychainAccessCredentials(),
        wallClock: any WallClock = SystemWallClock(), reload: @escaping @Sendable () -> Void
    ) -> IntentWriteContext {
        // Its own `flush` owner: the app (or another extension) may hold the lease meanwhile.
        let owner = LeaseClaim.owner(kind: "widget", launchId: UUID())
        return IntentWriteContext(
            origin: .widget,
            openActiveStore: {
                try await StorePartitions.open(at: location, wallClock: wallClock).openActiveStore(role: .extension)?
                    .store
            },
            afterCommit: { store in
                reload()
                await flush(store, owner: owner, transport: transport, credentials: credentials)
                reload()
            },
            wallClock: wallClock)
    }

    /// One bounded flush of `store` to its server; quiet when it can't (the entry stays queued).
    static func flush(
        _ store: LocalStore, owner: String, transport: any Transport, credentials: any AccessCredentialsProvider
    ) async {
        do {
            guard let state = try await store.syncState.syncState(), let url = URL(string: state.baseURL) else {
                return
            }
            let sender = APIClient(
                baseURL: url, transport: transport, identity: StaticServerIdentity(nil), credentials: credentials,
                origin: .widget)
            let policy = OutboxFlushPolicy.extensionFlush(budget: flushBudget)
            let report = try await Outbox(store: store, sender: sender, owner: owner).flush(
                force: policy.force, budget: policy.budget, leaseWait: policy.leaseWait)
            log.info("widget flush: \(String(describing: report.ending), privacy: .public)")
        } catch {
            log.notice("widget flush skipped, the entry stays queued: \(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "widget-writes")
}
