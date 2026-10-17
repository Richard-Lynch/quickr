import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The `APIOutcome` table, row by row (outbox.md §5.1 and §5.2 step 0, sync-protocol.md §1.4).
@Suite struct ClassificationTests {
    typealias Outcome = APIOutcome<Entry>

    static let entryJSON: String = {
        let fixture = try! Fixtures.api("createEntry")
        return String(decoding: fixture.body!, as: UTF8.self)
    }()

    static let entry: Entry = try! Endpoints.createEntry.erased.decodeResponse(Data(entryJSON.utf8)) as! Entry

    static func classify(
        _ response: HTTPResponse, expected: ServerIdentity? = APITest.fixtureIdentity
    ) -> APIResponse<Entry> {
        APIClassifier.classify(.success(response), expected: expected) { response in
            try EntryDTO.decode(response.body, using: WireCoding.decoder()).toDomain()
        }
    }

    static func classify(_ error: TransportError) -> APIResponse<Entry> {
        APIClassifier.classify(.failure(error), expected: APITest.fixtureIdentity) { _ in entry }
    }

    static func problem(_ code: ProblemCode, _ detail: String = "something happened") -> Problem {
        Problem(code: code, detail: detail)
    }

    // MARK: No response

    @Test func noResponseBeforeTheRequestStartedIsRetryable() {
        let result = Self.classify(.unreachable("offline"))
        #expect(result.outcome == .retryable(.noResponse(.unreachable("offline"))))
        #expect(!result.outcome.setsMaybeDelivered && result.outcome.stopsPass && result.outcome.isRetry)
        #expect(result.status == nil && result.message == "Could not reach the server")
        #expect(result.errorInfo == OutboxErrorInfo(message: "Could not reach the server", status: nil, body: nil))
    }

    @Test(arguments: [
        TransportError.timedOut(requestStarted: true), .cancelled(requestStarted: true),
        .failed("connection lost", requestStarted: true),
    ])
    func noResponseAfterTheRequestStartedIsUncertain(_ error: TransportError) {
        let result = Self.classify(error)
        #expect(result.outcome == .uncertain(.noResponse(error)))
        #expect(result.outcome.setsMaybeDelivered && result.outcome.stopsPass && result.outcome.isRetry)
        #expect(result.message == "Could not reach the server")
    }

    @Test func timeoutBeforeStartIsRetryable() {
        #expect(Self.classify(.timedOut(requestStarted: false)).outcome.setsMaybeDelivered == false)
    }

    // MARK: 2xx

    @Test func decodable2xxIsSuccess() {
        let result = Self.classify(APITest.response(201, json: Self.entryJSON))
        #expect(result.outcome == .success(Self.entry))
        #expect(result.identity == APITest.fixtureIdentity && result.expected == APITest.fixtureIdentity)
        #expect(result.message == nil && result.errorInfo == nil && result.value == Self.entry)
    }

    @Test(arguments: [
        ("<html><body>Sign in to Wi-Fi</body></html>", "captive portal"),
        ("", "empty"),
        (#"{"id": "not a uuid"}"#, "missing fields"),
        ("{not json", "not JSON"),
    ])
    func undecodable2xxIsUncertain(body: String, label: String) throws {
        let result = Self.classify(APITest.response(200, json: body, headers: ["Content-Type": "text/html"]))
        guard case .uncertain(.undecodableSuccess(let status, _)) = result.outcome else {
            Issue.record("\(label): \(result.outcome)")
            return
        }
        #expect(status == 200)
        #expect(result.outcome.isRetry && result.outcome.setsMaybeDelivered && !result.outcome.stopsPass)
        #expect(result.message == "Unexpected response from the server")
    }

    /// A captive portal that also strips headers is an identity mismatch, never a success.
    @Test func captivePortalWithoutHeadersIsNeverSuccess() {
        let result = Self.classify(APITest.response(200, json: "<html></html>", identity: nil))
        #expect(result.outcome == .identityMismatch(.missingHeaders(status: 200)))
        #expect(result.outcome.setsMaybeDelivered && result.outcome.stopsPass)
    }

    @Test func a2xxThatMapsBadlyIsUncertain() throws {
        // Decodes as JSON but the id isn't a UUID: a contract violation, not a success.
        var object = try #require(try JSONSerialization.jsonObject(with: Data(Self.entryJSON.utf8)) as? [String: Any])
        object["id"] = "nope"
        let body = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        guard case .uncertain(.undecodableSuccess) = Self.classify(APITest.response(201, json: body)).outcome else {
            Issue.record("expected uncertain")
            return
        }
    }

    // MARK: Identity and epoch (step 0)

    @Test func a2xxWithoutHeadersIsAnIdentityMismatch() {
        for headers in [[:], [QuickrHeader.serverId: APITest.fixtureIdentity.serverId]] {
            var response = APITest.response(201, json: Self.entryJSON, identity: nil)
            for (name, value) in headers { response.headers[name] = value }
            #expect(Self.classify(response).outcome == .identityMismatch(.missingHeaders(status: 201)))
        }
    }

    @Test func serverHeaderMismatchIsCheckedOnEveryStatus() {
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.fixtureIdentity.epoch)
        for status in [200, 201, 204, 302, 400, 401, 404, 409, 422, 500] {
            let body = status < 300 ? Self.entryJSON : APITest.problem("entry_deleted")
            let result = Self.classify(APITest.response(status, json: body, identity: other))
            #expect(result.outcome == .identityMismatch(.responseHeaders(observed: other)), "\(status)")
            #expect(result.outcome.setsMaybeDelivered && result.outcome.stopsPass)
            #expect(result.identity == other && result.outcome.problem == nil)
        }
    }

    @Test func epochHeaderMismatchIsCheckedOnEveryStatus() {
        let other = ServerIdentity(serverId: APITest.fixtureIdentity.serverId, epoch: APITest.otherEpoch)
        for status in [200, 201, 302, 404, 409, 410, 422, 503] {
            let body = status < 300 ? Self.entryJSON : APITest.problem("not_found")
            let result = Self.classify(APITest.response(status, json: body, identity: other))
            #expect(result.outcome == .epochMismatch(.responseHeaders(observed: other)), "\(status)")
            #expect(result.outcome.setsMaybeDelivered && result.outcome.stopsPass)
        }
    }

    /// A 404 or 409 from another epoch never means "gone" or "deleted" (outbox.md §5.2 step 0).
    @Test func gonePresumingStatusesFromAnotherEpochAreNotInterpreted() {
        let other = ServerIdentity(serverId: APITest.fixtureIdentity.serverId, epoch: APITest.otherEpoch)
        for (status, code) in [(404, "not_found"), (409, "entry_deleted"), (409, "stale_revision")] {
            let outcome = Self.classify(APITest.response(status, json: APITest.problem(code), identity: other)).outcome
            #expect(outcome == .epochMismatch(.responseHeaders(observed: other)))
        }
    }

    @Test func serverIdIsCheckedBeforeEpoch() {
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.otherEpoch)
        let outcome = Self.classify(APITest.response(200, json: Self.entryJSON, identity: other)).outcome
        #expect(outcome == .identityMismatch(.responseHeaders(observed: other)))
    }

    @Test func preconditionRejectionsExecutedNothing() {
        let observed = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.otherEpoch)
        let server = Self.classify(APITest.response(409, json: APITest.problem("server_mismatch"), identity: observed))
        #expect(server.outcome == .identityMismatch(.preconditionRejected(observed: observed)))
        #expect(!server.outcome.setsMaybeDelivered && server.outcome.stopsPass && !server.outcome.isRetry)

        let sameServer = ServerIdentity(serverId: APITest.fixtureIdentity.serverId, epoch: APITest.otherEpoch)
        let epoch = Self.classify(APITest.response(409, json: APITest.problem("epoch_mismatch"), identity: sameServer))
        #expect(epoch.outcome == .epochMismatch(.preconditionRejected(observed: sameServer)))
        #expect(!epoch.outcome.setsMaybeDelivered && epoch.outcome.stopsPass)
    }

    /// Without an expected identity (bootstrap) only the header presence is checked; the
    /// response identity is exposed for the caller to adopt.
    @Test func withoutAnExpectedIdentityHeadersAreExposedNotCompared() {
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.otherEpoch)
        let result = Self.classify(APITest.response(200, json: Self.entryJSON, identity: other), expected: nil)
        #expect(result.outcome == .success(Self.entry) && result.identity == other && result.expected == nil)
        let missing = Self.classify(APITest.response(200, json: Self.entryJSON, identity: nil), expected: nil)
        #expect(missing.outcome == .identityMismatch(.missingHeaders(status: 200)))
    }

    @Test func identityComparisonIgnoresCase() {
        let upper = ServerIdentity(
            serverId: APITest.fixtureIdentity.serverId.uppercased(), epoch: APITest.fixtureIdentity.epoch.uppercased())
        #expect(
            Self.classify(APITest.response(201, json: Self.entryJSON, identity: upper)).outcome == .success(Self.entry))
    }

    // MARK: Non-2xx without headers (never an application error)

    @Test(arguments: [301, 302, 303, 307, 308])
    func redirectWithoutHeadersIsRetryable(status: Int) {
        let result = Self.classify(
            APITest.response(status, identity: nil, headers: ["Location": "https://login.example"]))
        #expect(result.outcome == .retryable(.redirect(status: status)))
        #expect(!result.outcome.setsMaybeDelivered && !result.outcome.stopsPass)
        #expect(result.message == "The server redirected the request (sign-in required?)")
    }

    @Test(arguments: [401, 403, 408, 425, 429])
    func retryable4xxWithoutHeadersIgnoresTheBody(status: Int) {
        // An Access proxy's body that happens to look like a Problem is still not read as one.
        let result = Self.classify(APITest.response(status, json: APITest.problem("conflict", "denied"), identity: nil))
        #expect(result.outcome == .retryable(.status(status, nil)))
        #expect(!result.outcome.setsMaybeDelivered)
        #expect(result.message == "Denied", "the PWA's message still uses any JSON detail")
    }

    @Test(arguments: [500, 502, 503, 504])
    func serverErrorWithoutHeadersIsUncertain(status: Int) {
        let result = Self.classify(APITest.response(status, json: "<html>Bad gateway</html>", identity: nil))
        #expect(result.outcome == .uncertain(.serverError(status: status, problem: nil)))
        #expect(result.outcome.setsMaybeDelivered && !result.outcome.stopsPass)
        #expect(result.message == "Server error (\(status))")
    }

    @Test(arguments: [400, 404, 409, 410, 422, 451])
    func otherStatusesWithoutHeadersAreRetriedNeverTerminal(status: Int) {
        let result = Self.classify(APITest.response(status, json: APITest.problem("entry_deleted"), identity: nil))
        #expect(result.outcome == .retryable(.unexpectedResponse(status: status)))
        #expect(!result.outcome.setsMaybeDelivered)
        #expect(result.message == "Unexpected response from the server")
    }

    // MARK: Non-2xx from the expected server and epoch

    @Test func redirectWithHeadersIsRetryable() {
        #expect(Self.classify(APITest.response(307)).outcome == .retryable(.redirect(status: 307)))
    }

    @Test(arguments: [401, 403, 408, 425, 429])
    func retryable4xxKeepsItsProblem(status: Int) {
        let result = Self.classify(APITest.response(status, json: APITest.problem("bad_request", "slow down")))
        #expect(result.outcome == .retryable(.status(status, Self.problem(.badRequest, "slow down"))))
        #expect(result.message == "Slow down")
    }

    @Test func notFoundIsSplitOut() {
        let result = Self.classify(APITest.response(404, json: APITest.problem("not_found", "no such entry")))
        #expect(result.outcome == .notFound(Self.problem(.notFound, "no such entry")))
        #expect(!result.outcome.isRetry && !result.outcome.setsMaybeDelivered)
        #expect(result.errorInfo?.status == 404 && result.errorInfo?.message == "No such entry")
        // A 404 without a Problem body (but with the headers) is still a 404.
        #expect(Self.classify(APITest.response(404, json: "Not Found")).outcome == .notFound(nil))
    }

    @Test func entryDeletedAndStaleRevisionAreSplitOut() {
        let deleted = Self.classify(APITest.response(409, json: APITest.problem("entry_deleted"))).outcome
        #expect(deleted == .entryDeleted(Self.problem(.entryDeleted)))
        let stale = Self.classify(APITest.response(409, json: APITest.problem("stale_revision"))).outcome
        #expect(stale == .staleRevision(Self.problem(.staleRevision)))
        // Only as 409s: the same code on another status is just a terminal 4xx.
        let odd = Self.classify(APITest.response(400, json: APITest.problem("entry_deleted"))).outcome
        #expect(odd == .terminal(status: 400, problem: Self.problem(.entryDeleted)))
    }

    @Test(arguments: [
        (409, "conflict"), (409, "topic_archived"), (409, "incompatible_version"), (422, "invalid_answers"),
        (422, "invalid_request"), (400, "bad_request"), (410, "gone_somewhere"), (409, "brand_new_code"),
    ])
    func other4xxAreTerminal(status: Int, code: String) {
        let result = Self.classify(APITest.response(status, json: APITest.problem(code, "  nope  ")))
        #expect(
            result.outcome == .terminal(status: status, problem: Self.problem(ProblemCode(rawValue: code), "  nope  ")))
        #expect(!result.outcome.isRetry && !result.outcome.setsMaybeDelivered)
        #expect(result.message == "Nope")
    }

    @Test func terminal4xxWithoutAProblemBodyFallsBackToTheStatus() {
        let result = Self.classify(APITest.response(400, json: "oops"))
        #expect(result.outcome == .terminal(status: 400, problem: nil))
        #expect(result.message == "Request failed (400)")
    }

    @Test func serverErrorWithHeadersIsUncertain() {
        let result = Self.classify(
            APITest.response(500, json: APITest.problem("internal_error", "internal server error")))
        #expect(
            result.outcome
                == .uncertain(.serverError(status: 500, problem: Self.problem(.internalError, "internal server error")))
        )
        #expect(result.outcome.setsMaybeDelivered)
        #expect(result.message == "Internal server error", "the PWA prefers the detail, even for a 5xx")
        #expect(
            result.errorInfo?.body
                == .object([
                    "code": .string("internal_error"), "detail": .string("internal server error"), "errors": .array([]),
                ]))
    }

    @Test(arguments: [100, 199, 600, 999])
    func statusesOutsideTheTableAreRetried(status: Int) {
        #expect(Self.classify(APITest.response(status)).outcome == .retryable(.unexpectedResponse(status: status)))
    }

    // MARK: Fixtures

    /// Every recorded problem decodes and classifies to the outcome its status and code give.
    @Test(arguments: try Fixtures.apiNames().filter { try !Fixtures.api($0).isSuccess })
    func problemFixturesClassify(name: String) throws {
        let fixture = try Fixtures.api(name)
        let endpoint = try #require(Endpoints.named(fixture.operationId))
        let result = APIClassifier.classify(.success(fixture.response()), expected: APITest.fixtureIdentity) {
            try endpoint.decodeResponse($0.body)
        }
        let problem = try Endpoints.decodeProblem(try #require(fixture.body))
        #expect(result.outcome.problem == problem, "\(name)")
        switch (fixture.status, problem.code) {
        case (404, _): #expect(result.outcome.isNotFound)
        case (409, .entryDeleted): #expect(result.outcome.isEntryDeleted)
        default: #expect(result.outcome.terminalStatus == fixture.status, "\(name): \(result.outcome)")
        }
    }

    /// Every recorded success decodes to `.success` through the classifier.
    @Test(arguments: try Fixtures.apiNames().filter { try Fixtures.api($0).isSuccess })
    func successFixturesClassify(name: String) throws {
        let fixture = try Fixtures.api(name)
        let endpoint = try #require(Endpoints.named(fixture.operationId))
        let result = APIClassifier.classify(.success(fixture.response()), expected: APITest.fixtureIdentity) {
            try endpoint.decodeResponse($0.body)
        }
        #expect(result.outcome.isSuccess, "\(name): \(result.outcome)")
    }
}

extension APIOutcome {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    fileprivate var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    fileprivate var isEntryDeleted: Bool {
        if case .entryDeleted = self { return true }
        return false
    }

    fileprivate var terminalStatus: Int? {
        if case .terminal(let status, _) = self { return status }
        return nil
    }
}
