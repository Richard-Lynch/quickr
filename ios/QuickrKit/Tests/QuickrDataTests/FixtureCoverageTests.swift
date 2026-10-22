import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// G1 (sync-protocol.md §13.2): every recorded response decodes into its DTO and maps to the
/// domain, every fixture's operation is in the endpoint table, and every JSON endpoint has a
/// fixture. A fixture without a DTO mapping fails here.
@Suite(.timeLimit(.minutes(5))) struct FixtureCoverageTests {
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

    /// Every key of every response object is required in `openapi.json` (nullable ones too), so
    /// a response missing any one of them must fail to decode, never default to nil (sync §2.2).
    /// Free-form maps (`meta`, `option_counts`, `json_schema`, `/health`) have no required keys.
    @Test(arguments: try Fixtures.apiNames().filter { $0 != "health" })
    func responseMissingAnyKeyFailsToDecode(name: String) throws {
        let fixture = try Fixtures.api(name)
        guard fixture.isSuccess, let body = fixture.body else { return }
        let endpoint = try #require(Endpoints.named(fixture.operationId))
        let root = try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
        let variants = Self.withOneKeyRemoved(root, path: "")
        for (path, variant) in variants {
            let data = try JSONSerialization.data(withJSONObject: variant, options: .fragmentsAllowed)
            #expect(throws: (any Error).self, "\(name): decoded without \(path)") {
                try endpoint.decodeResponse(data)
            }
        }
        if fixture.operationId != "sendTestPush" && fixture.operationId != "getPushConfig" {
            #expect(!variants.isEmpty || name.hasPrefix("delete"))
        }
    }

    /// Required-but-nullable keys accept `null`.
    @Test func requiredNullableKeysAcceptNull() throws {
        let body = try #require(try Fixtures.api("getTopic").body)
        var object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        for key in ["schedule", "schedule_updated_at", "archived_at", "last_captured_at", "due"] {
            object[key] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let topic = try Endpoints.getTopic.erased.decodeResponse(data) as? Topic
        #expect(topic?.schedule == nil && topic?.due == nil && topic?.archivedAt == nil)
    }

    private static let freeFormMaps: Set<String> = ["meta", "option_counts", "json_schema"]

    /// Every copy of `value` with exactly one object key removed, with the removed key's path.
    static func withOneKeyRemoved(_ value: Any, path: String) -> [(String, Any)] {
        if let object = value as? [String: Any] {
            var variants: [(String, Any)] = []
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                var removed = object
                removed[key] = nil
                variants.append(("\(path)/\(key)", removed))
                guard !freeFormMaps.contains(key) else { continue }
                for (childPath, childVariant) in withOneKeyRemoved(child, path: "\(path)/\(key)") {
                    var copy = object
                    copy[key] = childVariant
                    variants.append((childPath, copy))
                }
            }
            return variants
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, element in
                withOneKeyRemoved(element, path: "\(path)/\(index)").map { childPath, childVariant in
                    var copy = array
                    copy[index] = childVariant
                    return (childPath, copy as Any)
                }
            }
        }
        return []
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
