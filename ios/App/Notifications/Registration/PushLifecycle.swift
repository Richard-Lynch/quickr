import Foundation
import Observation
import QuickrCore
import QuickrData
import UIKit
import UserNotifications

/// The app's side of APNs registration (notifications.md §9): the system calls in, the session's
/// binding, and `PushRegistration` (QuickrData) for the rules. App process only.
///
/// - Launch and activation: ``activated(coldLaunch:)``.
/// - A new binding: ``bindingChanged()``, which deletes the token from the previous server when the
///   server changed (with that server's last known epoch).
/// - Permission granted in Settings or onboarding: ``permissionGranted()``.
/// - `didRegisterForRemoteNotificationsWithDeviceToken`, through `RemoteNotificationTokens`.
@MainActor @Observable
final class PushLifecycle {
    let registration: PushRegistration
    private let session: AppSession
    /// The server the app was last bound to, with its epoch: what a switch deletes the token from.
    @ObservationIgnored private var lastServer: PushRegistration.Server?

    /// Observable: `PushRegistration` is.
    var status: PushRegistration.Status { registration.status }

    init(session: AppSession, transport: any Transport, credentials: any AccessCredentialsProvider) {
        self.session = session
        let bundle = Bundle.main
        registration = PushRegistration(
            dependencies: .init(
                registry: session.partitions.registry, transport: transport, credentials: credentials,
                environment: { PushEnvironment.current },
                authorization: { await SystemNotificationCenter().authorizationStatus() },
                requestToken: { UIApplication.shared.registerForRemoteNotifications() },
                bundleId: bundle.bundleIdentifier,
                appVersion: [
                    bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                    (bundle.infoDictionary?["CFBundleVersion"] as? String).map { "(\($0))" },
                ].compactMap(\.self).joined(separator: " "),
                // The name the user gave the device (iOS 16+: the model unless entitled). Never a
                // serial number or a MAC.
                deviceName: UIDevice.current.name))
        registration.recoverActiveEpoch = { [weak self] in await self?.rebuild() }
        RemoteNotificationTokens.shared.receiver = self
    }

    // MARK: - Events

    func activated(coldLaunch: Bool) async {
        let active = await activeServer()
        if let active { lastServer = active }
        await registration.activated(active: active, coldLaunch: coldLaunch)
    }

    /// After a rebind: a server switch deletes the token from the old server, then registers
    /// with the new one.
    func bindingChanged() async {
        let active = await activeServer()
        if let previous = lastServer, previous.identity.serverId != active?.identity.serverId {
            await registration.serverSwitched(from: previous)
        }
        lastServer = active ?? lastServer
        if active != nil { await registration.activated(active: active, coldLaunch: true) }
    }

    func permissionGranted() async {
        await activated(coldLaunch: true)
    }

    func didRegister(token: Data) async {
        await registration.didRegister(token: token, active: await activeServer())
    }

    func didFailToRegister(_ error: any Error) async {
        await registration.didFailToRegister(error)
    }

    func testThisDevice() async -> PushRegistration.TestOutcome {
        guard let active = await activeServer() else { return .notRegistered }
        return await registration.testThisDevice(active: active)
    }

    // MARK: - Pieces

    /// The bound store's server: its id and epoch (from `sync_state`) and its address.
    private func activeServer() async -> PushRegistration.Server? {
        guard let binding = session.binding, let store = session.store,
            let state = try? await store.syncState.syncState(), let epoch = state.epoch
        else { return nil }
        return PushRegistration.Server(
            identity: ServerIdentity(serverId: binding.serverId, epoch: epoch), baseURL: binding.baseURL)
    }

    /// §9.2: `epoch_mismatch` from the active server: the coordinator rebuilds (sync-protocol.md
    /// §7). The active server afterwards when the sync succeeded, else nil (the registration then
    /// waits out its backoff instead of asking for another rebuild).
    private func rebuild() async -> PushRegistration.Server? {
        guard await session.coordinator.sync(reason: .requested) == .synced else { return nil }
        return await activeServer()
    }
}

/// `UIApplication`'s token callbacks arrive in the app delegate; it hands them on here.
@MainActor
final class RemoteNotificationTokens {
    static let shared = RemoteNotificationTokens()
    weak var receiver: PushLifecycle?

    func didRegister(_ token: Data) {
        guard let receiver else { return }
        Task { await receiver.didRegister(token: token) }
    }

    func didFail(_ error: any Error) {
        guard let receiver else { return }
        Task { await receiver.didFailToRegister(error) }
    }
}

/// This build's APNs environment (§9.1): `sandbox` on the simulator (decided at compile time),
/// else read from the embedded provisioning profile.
enum PushEnvironment {
    static var current: Result<ApnsEnvironment, ProvisioningProfile.Failure> {
        #if targetEnvironment(simulator)
        .success(.sandbox)
        #else
        ProvisioningProfile.apnsEnvironment(
            profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
                .flatMap { try? Data(contentsOf: $0) })
        #endif
    }
}
