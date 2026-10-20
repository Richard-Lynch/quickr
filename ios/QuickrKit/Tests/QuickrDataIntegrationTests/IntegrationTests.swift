import Foundation
import QuickrData
import Testing

/// Gate G4 (sync-protocol.md §13.2): the INT cases of the sync and outbox matrices against real
/// backends (`make ios-integration`). Every test shares the harness's proxy and databases, so the
/// suite runs one test at a time; each test resets the proxy and makes its own topics.
@Suite(
    "Integration (make ios-integration)", .serialized,
    .enabled(if: ITConfig.current != nil, "needs the harness's environment: run make ios-integration"))
struct IntegrationTests {}

/// Under `make ios-integration` a missing environment is a failure, not a skip.
@Suite(.timeLimit(.minutes(2))) struct IntegrationHarnessTests {
    @Test func environmentIsSetWhenRequired() {
        #expect(
            !ITConfig.isRequired || ITConfig.current != nil,
            "QUICKR_IT_REQUIRED=1 but the integration environment is missing (ios/build/integration.env)")
    }
}

/// One test's view of the harness: the proxy (reset, routing to server a), and both servers as the
/// web reaches them.
struct IT {
    let config: ITConfig
    let proxy: FaultProxy
    /// Server a, directly.
    let a: WebServer
    /// Server b, directly.
    let b: WebServer

    static func start() async throws -> IT {
        let config = try ITConfig.require()
        let it = IT(
            config: config, proxy: FaultProxy(http: HTTP(base: config.controlURL)),
            a: WebServer(http: HTTP(base: config.serverAURL)), b: WebServer(http: HTTP(base: config.serverBURL)))
        try await it.proxy.reset()
        return it
    }

    /// Runs `body` with a device onboarded to server a and a topic of its own, and shuts the
    /// device down afterwards on every path.
    func withDevice(
        pageLimit: Int = APIClient.feedPageLimit, _ body: (Device, LocalStore, TopicRef) async throws -> Void
    ) async throws {
        let topic = try await a.createTopic()
        let device = try Device(config, pageLimit: pageLimit)
        try await device.run {
            let store = try await device.connect()
            try await body(device, store, topic)
        }
    }
}
