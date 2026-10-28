import Foundation
import Testing

@testable import QuickR

/// Where Open TestFlight goes (client-versions.md §3.2): the server's `update_url.ios` when it is a
/// TestFlight or https link, the default otherwise.
@Suite struct ClientUpdateTests {
    @Test(arguments: [
        "itms-beta://", "itms-beta://beta.itunes.apple.com/v1/app/1", "https://testflight.apple.com/join/x",
    ])
    func aTestFlightOrHttpsLinkIsUsed(_ value: String) {
        let url: URL = ClientUpdate.updateURL(from: value)
        #expect(url.absoluteString == value)
    }

    @Test(arguments: [
        nil, "", "not a url", "http://example.com", "javascript:alert(1)", "quickr://settings", "file:///etc",
    ])
    func anythingElseIsTheDefault(_ value: String?) {
        let url: URL = ClientUpdate.updateURL(from: value)
        #expect(url == ClientUpdate.defaultUpdateURL)
    }
}
