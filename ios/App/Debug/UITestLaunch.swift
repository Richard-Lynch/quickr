#if DEBUG
import Foundation
import QuickrData

/// `-QuickrUITest` (DEBUG only): a clean slate for a UI test, so it never touches the real store,
/// settings or Keychain. A fresh store directory and defaults suite per launch, an in-memory
/// Keychain, and a fake quickR server at `https://quickr.test` (an empty feed); any other host
/// goes to the network, so a test can also onboard against the integration stack.
///
/// With it, `-QuickrServer <url>` presets the server (launch connects, skipping onboarding) and
/// `-QuickrOpen <url>` opens a link once the root is up (screenshots, deep-link checks).
enum UITestLaunch {
    static let argument = "-QuickrUITest"
    static let fakeServer = URL(string: "https://quickr.test")!
    static let fakeServerId = "00000000-0000-4000-8000-0000000000aa"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    @MainActor static func environment() -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-uitest-\(UUID().uuidString)")
        let suite = "quickr.uitest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let environment = AppEnvironment.live(
            location: StoreLocation(root: root), defaults: defaults, keychain: InMemoryKeychain(),
            transport: FakeServerTransport(fallback: URLSessionTransport()))
        environment.settings.serverURL = value(after: "-QuickrServer").flatMap(URL.init(string:))
        return environment
    }

    /// `-QuickrOpen <url>`, when testing.
    static var openURL: URL? {
        guard isActive else { return nil }
        return value(after: "-QuickrOpen").flatMap(URL.init(string:))
    }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// Answers `https://quickr.test/api/v1/changes` with an empty feed page from a fixed server, and
/// any other path there with a 404; passes every other host to `fallback`.
private struct FakeServerTransport: Transport {
    let fallback: any Transport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.host() == UITestLaunch.fakeServer.host() else { return try await fallback.send(request) }
        let identity: HTTPHeaders = [
            QuickrHeader.serverId: UITestLaunch.fakeServerId,
            QuickrHeader.epoch: "00000000-0000-4000-8000-0000000000bb",
            "Content-Type": "application/json",
        ]
        guard request.url.path() == "/api/v1/changes" else {
            return HTTPResponse(
                status: 404, headers: identity,
                body: Data(#"{"code":"not_found","detail":"Not found","errors":[]}"#.utf8))
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let page = #"""
            {"items": [], "deleted": [], "next": 0, "has_more": false, "head": 0,
             "epoch": "00000000-0000-4000-8000-0000000000bb", "server_id": "\#(UITestLaunch.fakeServerId)",
             "server_time": "\#(now)"}
            """#
        return HTTPResponse(status: 200, headers: identity, body: Data(page.utf8))
    }
}
#endif
