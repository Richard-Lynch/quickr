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
    /// origin `.widget` or `.siri`); then this device's activity (a Start requests one, I-LA), and
    /// after a write a flush within the intent's budget and a reload of the widgets and Controls.
    func handleRunIntent(_ request: RunIntentRequest) async throws -> RunIntentResult {
        // Before first unlock the store can't be opened (timers.md §13.5 item 6), nor the session
        // made: checked first, so the intent says so.
        guard UIApplication.shared.isProtectedDataAvailable else { throw RunActivityTaps.Failure.locked }
        guard let session else { throw RunActivityTaps.Failure.noHandler }
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
        // `device.live_activity` as I-LA stamps it: true only in the foreground. From the
        // background the server's push-to-start shows the run; reconciliation ends a duplicate.
        let writes = session.runWrites(store: store, origin: request.origin)
        // Siri without a topic: the cooldown is the resolved topic's.
        var request = request
        if request.topicId == nil { request.topicId = try await writes.topicId(for: request) }
        if let topicId = request.topicId, !runActions.admits(topicId: topicId) {
            return RunIntentResult(.ignored(topic: nil), topicId: topicId)
        }
        var result = try await writes.perform(request)
        await liveActivities.reconcile(startFor: result.started ? result.topicId : nil)
        if result.wrote {
            // Outdated: kept for the updated build (client-versions.md §4.1). A flush that meets
            // the 426 first makes this result say so too.
            if !result.clientOutdated {
                await flushAfterActivityTap(store, session: session)
                result.clientOutdated = await ClientOutdated.isOutdated(store)
            }
            reloadWidgetsAndControls()
        }
        return result
    }

    /// Every timeline and Control: what a run intent changed shows everywhere at once (the
    /// widget whose button ran it is reloaded by WidgetKit anyway).
    private func reloadWidgetsAndControls() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
