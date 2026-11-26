import Foundation
import QuickrCore

// timers2.md §8.3 (R20): a reopen this device made requests the run's Live Activity locally, as a
// start does (`RunActivityPlan.actions(startFor:)`); one made elsewhere comes by push-to-start
// (the server sends `start` to every push-to-start token but the originating device's with
// `live_activity: true`). M2 owns `RunActivityCenter.swift` and the app's tap paths, and makes the
// one-line call: `await liveActivities.reconcile(after: result)` after a tap.

extension RunActivityPlan {
    /// The topic whose activity this device requests after its own tap: the reopened run's, when
    /// `result` enqueued a reopen; nil for any other tap, or when nothing was enqueued.
    public static func startFor(after result: OutboxEnqueueResult?) -> UUID? {
        guard case .appended(let item)? = result, item.kind == .runEvent,
            (try? item.runEventPayload())?.type == .reopen
        else { return nil }
        return UUID(uuidString: item.topicId)
    }
}

extension LiveActivities {
    /// `reconcile(startFor:)` after this device's tap: a reopen it enqueued requests the run's
    /// activity (`RunActivityPlan.startFor(after:)`); any other tap just reconciles.
    public func reconcile(after result: OutboxEnqueueResult?) async {
        await reconcile(startFor: RunActivityPlan.startFor(after: result))
    }
}
