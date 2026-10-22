import Foundation
import QuickrCore
import Testing

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("https://quickr.example.com", "https://quickr.example.com"),
        ("  quickr.example.com/  ", "https://quickr.example.com"),
        ("HTTPS://Quickr.Example.com:8443/", "https://quickr.example.com:8443"),
        ("https://nas.example.com/quickr/", "https://nas.example.com/quickr"),
        ("https://quickr.example.com/api/v1", "https://quickr.example.com"),
        ("https://quickr.example.com/api/v1/", "https://quickr.example.com"),
        ("https://quickr.example.com/t/water/record", "https://quickr.example.com"),
        ("https://nas.example.com/quickr/t/water", "https://nas.example.com/quickr"),
        ("https://quickr.example.com/settings", "https://quickr.example.com"),
        ("http://localhost:8100", "http://localhost:8100"),
        ("http://127.0.0.1:8100/", "http://127.0.0.1:8100"),
        ("http://192.168.1.20:8100", "http://192.168.1.20:8100"),
        ("http://10.0.0.5", "http://10.0.0.5"),
        ("http://172.20.1.1", "http://172.20.1.1"),
        ("http://nas.local:8100", "http://nas.local:8100"),
        ("http://nas:8100", "http://nas:8100"),
    ])
    func acceptsAndNormalises(_ input: String, _ expected: String) {
        #expect(ServerAddress.parse(input) == .success(URL(string: expected)!))
    }

    @Test(arguments: [
        ("", ServerAddress.Problem.empty),
        ("   ", .empty),
        ("quickr example.com", .malformed),
        ("https://", .malformed),
        ("https://.example.com", .malformed),
        ("https://exa mple.com", .malformed),
        ("ftp://quickr.example.com", .unsupportedScheme("ftp")),
        ("javascript://alert(1)", .unsupportedScheme("javascript")),
        ("http://quickr.example.com", .insecure),
        ("http://8.8.8.8", .insecure),
        ("http://172.32.0.1", .insecure),
        ("https://me:secret@quickr.example.com", .hasCredentials),
        ("https://quickr.example.com/?x=1", .hasQueryOrFragment),
        ("https://quickr.example.com/#top", .hasQueryOrFragment),
    ])
    func rejectsWithAReason(_ input: String, _ problem: ServerAddress.Problem) {
        #expect(ServerAddress.parse(input) == .failure(problem))
    }

    @Test func everyProblemHasAMessage() {
        let problems: [ServerAddress.Problem] = [
            .empty, .malformed, .unsupportedScheme("ftp"), .insecure, .hasCredentials, .hasQueryOrFragment,
        ]
        for problem in problems { #expect(!problem.description.isEmpty) }
        #expect(ServerAddress.Problem.insecure.description.contains("local network"))
    }

    @Test func localHosts() {
        for host in ["localhost", "LOCALHOST", "app.localhost", "nas.local", "nas", "::1", "10.1.2.3", "169.254.1.1"] {
            #expect(ServerAddress.isLocal(host), "\(host)")
        }
        for host in ["example.com", "8.8.8.8", "172.15.0.1", "192.169.0.1", "256.1.1.1", "10.0.0"] {
            #expect(!ServerAddress.isLocal(host), "\(host)")
        }
    }
}
