import Foundation
import QuickrCore
import Testing

@testable import QuickR

@Test func appSeesCoreVersion() {
    #expect(QuickrCore.version == "0.1.0")
}

/// Runs the Swift 6 + GRDB pattern inside the app process on the simulator.
@Test func appOpensAStoreThroughQuickrData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try await StoreLink.probe(directory: directory))
}
