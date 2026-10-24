import ActivityKit
import Foundation
import QuickrCore
import QuickrData

/// ActivityKit behind `RunActivityCenter` (timers.md §10.3), and the token streams: the device's
/// push-to-start token and each activity's update token go to `tokens`, then `tokensChanged`
/// registers them. Device only in practice: the logic is tested with a fake centre (R8).
@MainActor
final class SystemRunActivityCenter: RunActivityCenter {
    private var tokens: LiveActivityTokens?
    private var tokensChanged: (@MainActor () async -> Void)?
    /// The activities whose update tokens are being read.
    private var watched: Set<String> = []
    private var streams: [Task<Void, Never>] = []

    isolated deinit {
        for stream in streams { stream.cancel() }
    }

    /// Starts reading the token streams, once: the push-to-start token, new activities (ours and
    /// push-to-start's), and each activity's update token.
    func watch(tokens: LiveActivityTokens, changed: @escaping @MainActor () async -> Void) {
        guard self.tokens == nil else { return }
        self.tokens = tokens
        tokensChanged = changed
        streams.append(
            Task { [weak self] in
                for await data in Activity<RunActivityAttributes>.pushToStartTokenUpdates {
                    await tokens.pushToStart(Self.hex(data))
                    await self?.tokensChanged?()
                }
            })
        streams.append(
            Task { [weak self] in
                for await activity in Activity<RunActivityAttributes>.activityUpdates {
                    self?.watch(activity)
                }
            })
        for activity in Activity<RunActivityAttributes>.activities { watch(activity) }
    }

    private func watch(_ activity: Activity<RunActivityAttributes>) {
        guard let tokens, watched.insert(activity.id).inserted else { return }
        let id = activity.id
        streams.append(
            Task { [weak self] in
                for await data in activity.pushTokenUpdates {
                    await tokens.update(Self.hex(data), activityId: id)
                    await self?.tokensChanged?()
                }
            })
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: - RunActivityCenter

    func areActivitiesEnabled() async -> Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func activities() async -> [RunActivityRecord] {
        Activity<RunActivityAttributes>.activities.map { activity in
            RunActivityRecord(
                id: activity.id, attributes: activity.attributes, state: activity.content.state,
                staleDate: activity.content.staleDate, phase: Self.phase(activity.activityState))
        }
    }

    func request(_ attributes: RunActivityAttributes, _ state: RunActivityState, staleDate: Date) async throws
        -> String
    {
        let activity = try Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: .token)
        watch(activity)
        return activity.id
    }

    /// Nonisolated, like ActivityKit's own calls: an `Activity` isn't `Sendable`.
    nonisolated func update(id: String, _ state: RunActivityState, staleDate: Date) async {
        await Self.find(id)?.update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated func end(id: String, _ state: RunActivityState, dismissal: RunActivityDismissal) async {
        let policy: ActivityUIDismissalPolicy =
            switch dismissal {
            case .immediate: .immediate
            case .after(let date): .after(date)
            }
        await Self.find(id)?.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
    }

    private nonisolated static func find(_ id: String) -> Activity<RunActivityAttributes>? {
        Activity<RunActivityAttributes>.activities.first { $0.id == id }
    }

    private static func phase(_ state: ActivityState) -> RunActivityRecord.Phase {
        switch state {
        case .pending: .pending
        case .active: .active
        case .stale: .stale
        case .ended: .ended
        case .dismissed: .dismissed
        @unknown default: .ended
        }
    }
}
