import Foundation
import QuickrCore
import QuickrData
import UIKit
import WidgetKit

extension AppEnvironment {
    /// The run intents (timers.md §11.3): a timed widget's buttons, the Timer Control, the Action
    /// button and Siri. iOS runs them in this process (each is a `LiveActivityIntent`), launching
    /// it in the background if it was killed: the session may not have bound a store, so they
    /// write through the active one, like a Live Activity's buttons.
    func registerRunIntents() {
        RunIntents.register { [weak self] request in
            guard let self else { throw RunActivityTaps.Failure.noHandler }
            return try await self.handleRunIntent(request)
        }
    }

    /// One run intent: refused before first unlock, and for a widget drawn from another store;
    /// inside the topic's cooldown (shared with the app's controls and the Live Activity) it does
    /// nothing, so a double press doesn't Start then Stop. Otherwise the write (`RunWrites.perform`,
    /// origin `.widget` or `.siri`); then this device's activity (a Start requests one, I-LA), a
    /// flush within the intent's budget, and the widgets and Controls reload.
    func handleRunIntent(_ request: RunIntentRequest) async throws -> RunIntentResult {
        guard let session else { throw RunActivityTaps.Failure.noHandler }
        // Before first unlock the store can't be opened (timers.md §13.5 item 6).
        guard UIApplication.shared.isProtectedDataAvailable else { throw RunActivityTaps.Failure.locked }
        // Suspended in the background, the databases are resumed for the write.
        let hold = session.holdStoreResumed()
        defer { hold.release() }
        let store: LocalStore
        if let bound = session.store {
            store = bound
        } else if let opened = try await session.partitions.openActiveStore(role: .app)?.store {
            store = opened
        } else {
            throw IntentLogging.Failure.noStore
        }
        if let scope = request.scope, scope != store.scope {
            reloadWidgetsAndControls()
            throw RunIntents.Failure.stale
        }
        if let topicId = request.topicId, !runActions.admits(topicId: topicId) {
            return RunIntentResult(.ignored(topic: nil), topicId: topicId)
        }
        // iOS lets a `LiveActivityIntent` request an activity from the background, so a start
        // here says whether this device will show it (the server then skips its push-to-start).
        let activities = liveActivities
        let writes = session.runWrites(
            store: store, origin: request.origin, liveActivity: { await activities.willShowLocally() })
        let result = try await writes.perform(request)
        await liveActivities.reconcile(startFor: result.started ? result.topicId : nil)
        if result.wrote { await flushAfterActivityTap(store, session: session) }
        reloadWidgetsAndControls()
        return result
    }

    /// Every timeline and Control: what a run intent changed shows everywhere at once (the
    /// widget whose button ran it is reloaded by WidgetKit anyway).
    private func reloadWidgetsAndControls() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
