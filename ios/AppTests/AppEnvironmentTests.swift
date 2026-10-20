import Foundation
import QuickrData
import Testing

@testable import QuickR

@MainActor
@Test func settingsPersistTheServerURLInTheirSuite() throws {
    let suite = "skel-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    #expect(settings.serverURL == nil)
    settings.serverURL = URL(string: "https://quickr.example")
    #expect(AppSettings(defaults: defaults).serverURL == URL(string: "https://quickr.example"))
    settings.serverURL = nil
    #expect(AppSettings(defaults: defaults).serverURL == nil)
}

@MainActor
@Test func environmentStartsWithAnEmptyPathAndStartsTheSession() async throws {
    let seeded = try await TestStores.seededLocation()
    defer { TestStores.remove(seeded) }
    let environment = AppEnvironment.live(location: seeded)
    #expect(environment.router.path.isEmpty)
    #expect(environment.session != nil && environment.sessionError == nil)
    await environment.start()
    #expect(environment.session?.phase == .ready)
    #expect(try await environment.topics.topics().map(\.topic.name) == ["Coffee", "Mood", "Old habit"])
    await environment.session?.shutdown()
}

@MainActor
@Test func concurrentStartsShareOneSession() async throws {
    let location = TestStores.emptyLocation()
    defer { TestStores.remove(location) }
    let environment = AppEnvironment.live(location: location)
    let session = environment.session
    async let first: Void = environment.start()
    async let second: Void = environment.start()
    _ = await (first, second)
    await environment.start()
    #expect(environment.session === session)
    #expect(environment.session?.phase == .noServer)
    await environment.session?.shutdown()
}
