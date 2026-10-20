import Foundation
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

@Test func appSeesCoreVersion() {
    #expect(QuickrCore.version == "0.1.0")
}

/// The composition root inside the app process on the simulator: the session opens the registry
/// and, with no server configured, waits for onboarding.
@MainActor
@Test func appOpensASessionThroughQuickrData() async throws {
    let location = TestStores.emptyLocation()
    defer { TestStores.remove(location) }
    let session = try AppSession(
        configuration: .init(location: location, transport: URLSessionTransport(), notifier: nil))
    await session.start()
    #expect(session.phase == .noServer)
    await session.shutdown()
}
