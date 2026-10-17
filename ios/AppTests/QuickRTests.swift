import QuickrCore
import Testing

@testable import QuickR

@Test func appSeesCoreVersion() {
    #expect(QuickrCore.version == "0.1.0")
}
