import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// sync-protocol.md §13.1 S10 against the real backend: APNs registration across an epoch rotation.
extension IntegrationTests {
    @Suite("Push") struct PushCases {
        @Test(
            "S10 · APNs register after the epoch rotated: epoch_mismatch, rebuild, the register retried with the new epoch"
        )
        func s10() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, _ in
                let before = try await store.state()
                let oldEpoch = try #require(before.epoch)
                let old = PushRegistration.Server(
                    identity: ServerIdentity(serverId: it.config.serverId, epoch: oldEpoch), baseURL: it.config.proxyURL
                )
                let transport = RespondedTransport(device.transport)
                let registration = await MainActor.run {
                    let registration = PushRegistration(
                        dependencies: .init(
                            registry: device.partitions.registry, transport: transport,
                            environment: { .success(.sandbox) }, authorization: { .authorized }, requestToken: {},
                            bundleId: "com.bahumia.quickr", appVersion: "it", deviceName: "IT device",
                            leaseClock: device.clock))
                    // As the app wires it (PushLifecycle.rebuild): the coordinator syncs, which
                    // rebuilds the active store from the new epoch, and the active server is read back.
                    registration.recoverActiveEpoch = {
                        guard await device.coordinator.sync(reason: .requested) == .synced,
                            let epoch = try? await store.state().epoch
                        else { return nil }
                        return PushRegistration.Server(
                            identity: ServerIdentity(serverId: it.config.serverId, epoch: epoch),
                            baseURL: it.config.proxyURL)
                    }
                    return registration
                }

                let epoch = try await rotateEpoch(it.config)
                #expect(epoch != oldEpoch)
                let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                let index = device.sent().count  // after onboarding's own feed requests
                await registration.didRegister(token: token, active: old)

                // The first register, with the old epoch, is refused; the coordinator rebuilds; the
                // register goes again with the new epoch and the server takes it.
                let registers = transport.exchanges.filter { $0.request.url.path.hasSuffix("/push/apns/devices") }
                try #require(registers.count == 2, "\(registers.map(\.status))")
                #expect(registers[0].request.headers[QuickrHeader.expectEpoch] == oldEpoch)
                #expect(registers[0].status == 409 && registers[0].code == "epoch_mismatch")
                #expect(registers[1].request.headers[QuickrHeader.expectEpoch] == epoch)
                #expect(registers[1].status == 201)
                #expect(
                    registers[1].request.json?["token"] as? String == token.map { String(format: "%02x", $0) }.joined())
                #expect(await registration.status == .registered(serverId: it.config.serverId))

                // The rebuild happened between them: the store is on the new epoch, in a new layer
                // generation.
                let after = try await store.state()
                #expect(after.epoch == epoch && after.layerGen > before.layerGen && !after.epochSuspect)
                // In this order: the refused register, the rebuild's feed requests, the retried one.
                let order = device.sent(from: index).compactMap { request -> String? in
                    if request.url.path.hasSuffix("/push/apns/devices") { return "register" }
                    if request.url.path.hasSuffix("/changes") { return "feed" }
                    return nil
                }
                let firstFeed = try #require(order.firstIndex(of: "feed"), "the rebuild pulled the feed: \(order)")
                #expect(order.first == "register" && order.last == "register", "\(order)")
                #expect(order.dropFirst().prefix(upTo: order.count - 1).allSatisfy { $0 == "feed" } && firstFeed == 1)
            }
        }
    }
}

/// Records each request with the response it got (the status and the problem's code).
private final class RespondedTransport: Transport {
    struct Exchange: Sendable {
        var request: HTTPRequest
        var status: Int
        var code: String?
    }

    private let inner: any Transport
    private let recorded = Mutex<[Exchange]>([])

    init(_ inner: any Transport) { self.inner = inner }

    var exchanges: [Exchange] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await inner.send(request)
        let code = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["code"] as? String
        recorded.withLock { $0.append(Exchange(request: request, status: response.status, code: code)) }
        return response
    }
}
