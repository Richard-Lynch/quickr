import Foundation
import Observation
import QuickrCore

/// The §11.4 notices (timers.md) of the active store: a run tap of this device that the server
/// voided for a reason the user is told about. The ack keeps each one in the store
/// (`run_notice`), whichever process flushed it. One recorded while the app is on screen (active
/// since before it was recorded) is shown as a toast and then dropped; any other stays for the
/// sync sheet until it is dismissed, and is never toasted later. Lives in `AppEnvironment`; the
/// root runs `observe(_:)` per store binding, like `SyncController`.
@MainActor @Observable
public final class RunNoticeCenter {
    /// The notices the sync sheet lists, oldest first.
    public private(set) var notices: [RunNotice] = []
    /// The store `notices` come from.
    public private(set) var scope: EntryScope?

    /// Shows one notice as a toast (the app's toast centre).
    @ObservationIgnored private let toast: @MainActor (String) -> Void
    /// When the app last became active; nil while it isn't (in the background).
    @ObservationIgnored private var activeSince: Date?
    @ObservationIgnored private var store: LocalStore?
    @ObservationIgnored private let now: () -> Date

    public init(toast: @escaping @MainActor (String) -> Void, now: @escaping () -> Date = { Date() }) {
        self.toast = toast
        self.now = now
    }

    /// `scenePhase` → `.active`: notices recorded from now on are toasted.
    public func didBecomeActive() { activeSince = now() }

    /// `scenePhase` → `.background`: notices recorded from now on wait for the sync sheet.
    public func didEnterBackground() { activeSince = nil }

    /// Follows the active store's notices until the task is cancelled (a new binding) or the store
    /// closes.
    public func observe(_ session: AppSession) async {
        await observe(session.store, refresh: session.refresh.stream())
    }

    /// `observe(_:)` over `store` (nil: no store bound, nothing listed).
    public func observe(_ store: LocalStore?, refresh: AsyncStream<Void>? = nil) async {
        guard let store else {
            self.store = nil
            scope = nil
            notices = []
            return
        }
        self.store = store
        if scope != store.scope {
            notices = []
            scope = store.scope
        }
        do {
            for try await all in store.runNotices.observe(refresh: refresh) {
                await receive(all, from: store)
            }
        } catch {
            // the store closed (reset, server switch): the next binding observes again
        }
    }

    /// Toasts and drops the notices recorded while the app was on screen; lists the rest.
    public func receive(_ all: [RunNotice], from store: LocalStore) async {
        guard store.scope == scope else { return }
        let fresh = activeSince.map { since in all.filter { $0.createdAt >= since } } ?? []
        let freshIds = Set(fresh.map(\.id))
        notices = all.filter { !freshIds.contains($0.id) }
        for notice in fresh {
            toast(notice.text())
            try? await store.runNotices.dismiss(id: notice.id)
        }
    }

    /// The sync sheet's Dismiss.
    public func dismiss(_ notice: RunNotice) async throws {
        guard let store else { return }
        try await store.runNotices.dismiss(id: notice.id)
        notices.removeAll { $0.id == notice.id }
    }

    /// Long enough to read a sentence (the PWA's 6 s).
    public static let toastDuration: Duration = .seconds(6)
}
