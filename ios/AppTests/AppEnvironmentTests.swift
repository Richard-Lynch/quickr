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
@Test func environmentStartsWithAnEmptyPathAndOpensTheStore() async throws {
    let environment = AppEnvironment(settings: AppSettings(defaults: .standard), topics: PlaceholderTopicRepository())
    #expect(environment.router.path.isEmpty)
    await environment.start()
    #expect(environment.store != nil)
    #expect(environment.storeError == nil)
}
