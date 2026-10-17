import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// G1 (sync-protocol.md §13.2): every recorded response decodes into its DTO and maps to the
/// domain, every fixture's operation is in the endpoint table, and every JSON endpoint has a
/// fixture. A fixture without a DTO mapping fails here.
@Suite struct FixtureCoverageTests {
    @Test(arguments: try Fixtures.apiNames())
    func responseDecodesAndMaps(name: String) throws {
        let fixture = try Fixtures.api(name)
        let endpoint = try #require(Endpoints.named(fixture.operationId), "no endpoint for \(fixture.operationId)")
        #expect(endpoint.method.rawValue == fixture.method)
        let path = String(fixture.path.prefix { $0 != "?" })
        #expect(matches(path, template: endpoint.pathTemplate), "\(path) vs \(endpoint.pathTemplate)")

        var problem: Problem?
        if fixture.isSuccess {
            _ = try endpoint.decodeResponse(fixture.body ?? Data("null".utf8))
        } else {
            problem = try Endpoints.decodeProblem(try #require(fixture.body))
            #expect(problem?.detail.isEmpty == false)
            if case .unknown(let code) = problem?.code { Issue.record("unknown problem code \(code) in \(name)") }
        }

        // Request bodies decode into the request DTOs, except the ones the server rejected as
        // malformed: the DTOs must refuse those too (for example a naive `captured_at`).
        if let body = fixture.requestBody {
            #expect(endpoint.hasRequestBody, "\(name) sends a body to an endpoint without one")
            if problem?.code == .invalidRequest {
                #expect(throws: (any Error).self) { try endpoint.decodeRequestBody(body) }
            } else {
                _ = try endpoint.decodeRequestBody(body)
            }
        }
    }

    @Test func everyJSONEndpointHasASuccessFixture() throws {
        let fixtures = try Fixtures.allAPI()
        for endpoint in Endpoints.all where endpoint.hasJSONResponse {
            #expect(
                fixtures.contains { $0.operationId == endpoint.operationId && $0.isSuccess },
                "no success fixture for \(endpoint.operationId)")
        }
    }

    /// The table matches `openapi.json`: same operations, methods and paths.
    @Test func endpointTableMatchesOpenAPI() throws {
        let url = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("openapi.json")
        let spec = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let paths = try #require(spec["paths"] as? [String: [String: Any]])
        var operations: [String: (String, String)] = [:]
        for (path, methods) in paths {
            for (method, operation) in methods {
                guard let id = (operation as? [String: Any])?["operationId"] as? String else { continue }
                operations[id] = (method.uppercased(), path)
            }
        }
        #expect(Set(operations.keys) == Set(Endpoints.all.map(\.operationId)))
        for endpoint in Endpoints.all {
            guard let (method, path) = operations[endpoint.operationId] else { continue }
            #expect(endpoint.method.rawValue == method, "\(endpoint.operationId)")
            #expect(endpoint.pathTemplate == path, "\(endpoint.operationId)")
        }
    }

    @Test func mutationsAreTheNonGetOperationsExceptCheck() {
        for endpoint in Endpoints.all {
            #expect(endpoint.isMutation == (endpoint.method != .get && endpoint.operationId != "checkTopicVersion"))
        }
    }

    @Test func pathsArePercentEncoded() {
        #expect(Endpoints.getTopic.path(["ref": "a b/c"]) == "/api/v1/topics/a%20b%2Fc")
        #expect(
            Endpoints.getQuestionSeries.path(["ref": "sleep", "key": "hours"])
                == "/api/v1/topics/sleep/questions/hours/series")
    }

    private func matches(_ path: String, template: String) -> Bool {
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
        let templateParts = template.split(separator: "/", omittingEmptySubsequences: false)
        guard pathParts.count == templateParts.count else { return false }
        return zip(pathParts, templateParts).allSatisfy { part, pattern in
            if pattern.hasPrefix("{") { return !part.isEmpty }
            if pattern.contains("{") {  // `{ref}`-less suffixes like `entries.csv` never mix
                return false
            }
            return part == pattern
        }
    }
}
