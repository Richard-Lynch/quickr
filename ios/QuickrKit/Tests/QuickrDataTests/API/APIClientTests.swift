import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(5))) struct APIClientTests {
    static let topicId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let entryId = UUID(uuidString: "0f1e2d3c-4b5a-4968-8778-000000000001")!

    /// One call per operation, with sample arguments.
    static let calls: [String: @Sendable (APIClient) async throws -> APIResponse<any Sendable>] = [
        "health": { try await $0.health().erased },
        "listQuestionTypes": { try await $0.listQuestionTypes().erased },
        "getLimits": { try await $0.getLimits().erased },
        "listTopics": { try await $0.listTopics(status: "all").erased },
        "createTopic": {
            try await $0.createTopic(
                TopicCreateDTO(name: "X", questions: [Question(key: "k", label: "K", kind: .int(.init()))])
            ).erased
        },
        "getTopic": { try await $0.getTopic(ref: "everything").erased },
        "updateTopic": { try await $0.updateTopic(ref: "old-habit", TopicUpdateDTO(description: "Retired.")).erased },
        "deleteTopic": { try await $0.deleteTopic(ref: "old-habit").erased },
        "archiveTopic": { try await $0.archiveTopic(ref: "old-habit").erased },
        "unarchiveTopic": { try await $0.unarchiveTopic(ref: "old-habit").erased },
        "listTopicVersions": { try await $0.listTopicVersions(ref: "everything").erased },
        "publishTopicVersion": {
            try await $0.publishTopicVersion(
                ref: "everything", VersionCreateDTO(questions: [], baseVersion: 1, timer: nil)
            ).erased
        },
        "checkTopicVersion": {
            try await $0.checkTopicVersion(ref: "everything", VersionDraftDTO(questions: [], baseVersion: 2)).erased
        },
        "listEntries": { try await $0.listEntries(ref: "everything").erased },
        "createEntry": {
            try await $0.createEntry(
                ref: "everything", EntryCreateDTO(id: entryId, answers: [:], source: nil, capturedAt: nil, version: 1)
            ).erased
        },
        "exportEntriesCsv": { try await $0.exportEntriesCsv(ref: "everything").erased },
        "getEntry": { try await $0.getEntry(id: entryId).erased },
        "updateEntry": { try await $0.updateEntry(id: entryId, EntryUpdateDTO(notes: "Edited later.")).erased },
        "deleteEntry": { try await $0.deleteEntry(id: entryId).erased },
        "recordRunEvent": {
            let body = try WireCoding.decoder().decode(
                RunEventInDTO.self, from: Data(#"{"id": "x", "type": "pause", "at": "2026-03-04T11:00:00Z"}"#.utf8))
            return try await $0.recordRunEvent(runId: entryId, body).erased
        },
        "getRun": { try await $0.getRun(id: entryId).erased },
        "listRuns": { try await $0.listRuns(statuses: ["finishing"]).erased },
        "listChanges": { try await $0.listChanges(after: 0).erased },
        "getTopicStats": { try await $0.getTopicStats(ref: "everything").erased },
        "getTopicTiming": { try await $0.getTopicTiming(ref: "everything").erased },
        "getQuestionSeries": {
            try await $0.getQuestionSeries(ref: "everything", key: "hours", bucket: .day, timezone: "Europe/London")
                .erased
        },
        "getPushConfig": { try await $0.getPushConfig().erased },
        "createPushSubscription": {
            let body = try WireCoding.decoder().decode(
                PushSubscriptionInDTO.self,
                from: Data(#"{"endpoint": "https://x", "keys": {"p256dh": "a", "auth": "b"}}"#.utf8))
            return try await $0.createPushSubscription(body).erased
        },
        "deletePushSubscription": {
            let body = try WireCoding.decoder().decode(
                PushSubscriptionDeleteDTO.self, from: Data(#"{"endpoint": "https://x"}"#.utf8))
            return try await $0.deletePushSubscription(body).erased
        },
        "sendTestPush": { try await $0.sendTestPush().erased },
        "registerApnsDevice": {
            try await $0.registerApnsDevice(ApnsDeviceInDTO(token: "ab", environment: .sandbox)).erased
        },
        "deleteApnsDevice": { try await $0.deleteApnsDevice(ApnsDeviceRefDTO(token: "ab")).erased },
        "sendApnsTestPush": { try await $0.sendApnsTestPush(ApnsDeviceRefDTO(token: "ab")).erased },
    ]

    @Test func everyOperationHasATypedCall() {
        #expect(Set(Self.calls.keys) == Set(Endpoints.all.map(\.operationId)))
    }

    /// Each typed call hits its endpoint's method and path, and decodes the recorded success.
    @Test(arguments: try Fixtures.apiNames().filter { try Fixtures.api($0).isSuccess })
    func typedCallDecodesItsFixture(name: String) async throws {
        let fixture = try Fixtures.api(name)
        let transport = FakeTransport()
        transport.stub(where: { _ in true }, { _ in fixture.response() })
        let call = try #require(Self.calls[fixture.operationId])
        let result = try await call(APITest.client(transport))
        guard case .success = result.outcome else {
            Issue.record("\(name): \(result.outcome)")
            return
        }
        let request = try #require(transport.requests.first)
        let endpoint = try #require(Endpoints.named(fixture.operationId))
        #expect(request.method == endpoint.method)
        #expect(Self.matches(request.url.path(percentEncoded: true), endpoint.pathTemplate), "\(request.url)")
    }

    @Test func csvExportNeedsTheCSVContentType() async throws {
        let transport = FakeTransport()
        transport.enqueue(
            .success(
                APITest.response(200, json: "id,captured_at\n", headers: ["Content-Type": "text/csv; charset=utf-8"])))
        transport.enqueue(
            .success(APITest.response(200, json: "<html>portal</html>", headers: ["Content-Type": "text/html"])))
        let client = APITest.client(transport)
        #expect(try await client.exportEntriesCsv(ref: "x").value == Data("id,captured_at\n".utf8))
        guard case .uncertain(.undecodableSuccess) = try await client.exportEntriesCsv(ref: "x").outcome else {
            Issue.record("a captive portal is not a CSV")
            return
        }
        #expect(transport.requests[0].headers["Accept"] == "text/csv")
    }

    // MARK: Headers

    @Test func everyRequestIsDecorated() async throws {
        let transport = FakeTransport()
        let client = APITest.client(
            transport, credentials: AccessCredentials(clientId: "id.access", clientSecret: "s3cret"))
        for call in Self.calls.values { _ = try await call(client) }
        #expect(transport.requests.count == Self.calls.count)
        for request in transport.requests {
            #expect(request.headers[QuickrHeader.channel] == "ios")
            #expect(request.headers["Cache-Control"] == "no-store")
            #expect(request.headers[QuickrHeader.cfAccessClientId] == "id.access")
            #expect(request.headers[QuickrHeader.cfAccessClientSecret] == "s3cret")
            #expect((request.headers["Content-Type"] == "application/json") == (request.body != nil))
            #expect(request.url.host() == "quickr.example.com")
        }
    }

    @Test func accessHeadersOnlyWhenConfigured() async throws {
        let transport = FakeTransport()
        _ = try await APITest.client(transport).health()
        #expect(transport.requests[0].headers[QuickrHeader.cfAccessClientId] == nil)
        #expect(transport.requests[0].headers[QuickrHeader.cfAccessClientSecret] == nil)
    }

    @Test func expectHeadersOnlyOnMutations() async throws {
        let transport = FakeTransport()
        let client = APITest.client(transport)
        var byOperation: [String: HTTPRequest] = [:]
        for (operationId, call) in Self.calls {
            transport.reset()
            _ = try await call(client)
            byOperation[operationId] = transport.requests.first
        }
        for endpoint in Endpoints.all {
            let request = try #require(byOperation[endpoint.operationId])
            let serverId = request.headers[QuickrHeader.expectServerId]
            let epoch = request.headers[QuickrHeader.expectEpoch]
            if endpoint.isMutation {
                #expect(serverId == APITest.fixtureIdentity.serverId, "\(endpoint.operationId)")
                #expect(epoch == APITest.fixtureIdentity.epoch, "\(endpoint.operationId)")
            } else {
                #expect(serverId == nil && epoch == nil, "\(endpoint.operationId)")
            }
        }
        #expect(byOperation["checkTopicVersion"]?.headers[QuickrHeader.expectEpoch] == nil)
        #expect(byOperation["registerApnsDevice"]?.headers[QuickrHeader.expectEpoch] != nil)
    }

    /// The outbox sends with its claim's identity, and the response is checked against it.
    @Test func expectingOverridesTheProviderForHeadersAndChecks() async throws {
        let claim = ServerIdentity(serverId: APITest.fixtureIdentity.serverId, epoch: APITest.otherEpoch)
        let transport = FakeTransport()
        transport.enqueue(.success(try Fixtures.api("deleteEntry").response()))
        let result = try await APITest.client(transport).deleteEntry(id: Self.entryId, options: .init(expecting: claim))
        #expect(transport.requests[0].headers[QuickrHeader.expectEpoch] == APITest.otherEpoch)
        #expect(result.expected == claim)
        let observed = APITest.fixtureIdentity
        #expect(result.outcome == .epochMismatch(.responseHeaders(observed: ObservedIdentity(observed))))
    }

    @Test func readsAreCheckedAgainstTheStoreIdentity() async throws {
        let transport = FakeTransport()
        transport.enqueue(.success(try Fixtures.api("getTopic.not_found").response(epoch: APITest.otherEpoch)))
        let result = try await APITest.client(transport).getTopic(ref: "nope")
        guard case .epochMismatch(.responseHeaders) = result.outcome else {
            Issue.record("a 404 from another epoch must not read as not-found: \(result.outcome)")
            return
        }
    }

    @Test func aMutationWithoutAnIdentityIsNotSent() async throws {
        let transport = FakeTransport()
        let client = APITest.client(transport, identity: nil)
        await #expect(throws: APIClientError.noServerIdentity(operationId: "deleteEntry")) {
            try await client.deleteEntry(id: Self.entryId)
        }
        #expect(transport.requests.isEmpty)
        // Reads go out without one (bootstrap), and expose the response identity.
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))
        let page = try await client.listChanges(after: 0)
        #expect(page.identity == APITest.fixtureIdentity && page.expected == nil && page.value != nil)
    }

    @Test func providerFailuresAreThrown() async throws {
        struct Broken: ServerIdentityProvider, AccessCredentialsProvider {
            func currentIdentity() async throws -> ServerIdentity? { throw CocoaError(.fileReadCorruptFile) }
            func accessCredentials(for baseURL: URL) async throws -> AccessCredentials? {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let transport = FakeTransport()
        let client = APIClient(baseURL: APITest.baseURL, transport: transport, identity: Broken())
        await #expect(throws: APIClientError.self) { try await client.health() }
        let noCredentials = APIClient(
            baseURL: APITest.baseURL, transport: transport, identity: StaticServerIdentity(nil), credentials: Broken())
        await #expect(throws: APIClientError.self) { try await noCredentials.health() }
        #expect(transport.requests.isEmpty)
    }

    // MARK: Source

    @Test(arguments: OutboxOrigin.allCases)
    func createEntryDefaultsSourceToTheSurface(origin: OutboxOrigin) async throws {
        let transport = FakeTransport()
        let client = APITest.client(transport, origin: origin)
        _ = try await client.createEntry(
            ref: "t", EntryCreateDTO(id: Self.entryId, answers: [:], source: nil, capturedAt: nil, version: 1))
        _ = try await client.createEntry(
            ref: "t", EntryCreateDTO(id: Self.entryId, answers: [:], source: "ios.siri", capturedAt: nil, version: 1))
        let sources = try transport.requests.map {
            try WireCoding.decoder().decode(EntryCreateDTO.self, from: try #require($0.body)).source
        }
        #expect(sources == [origin.source, "ios.siri"], "an explicit source (the item's origin) wins")
        #expect(["ios", "ios.widget", "ios.notification", "ios.siri"].contains(origin.source))
    }

    // MARK: URLs, queries, bodies, timeouts

    @Test func urlsKeepTheBasePathAndEncodeQueries() async throws {
        let transport = FakeTransport()
        let client = APITest.client(transport, baseURL: URL(string: "https://example.com/quickr/")!)
        _ = try await client.listEntries(
            ref: "a b/c",
            filters: EntryFilters(
                capturedFrom: WireDate.parse("2026-03-01T08:00:00.5+01:00"), version: 2, source: "ios widget&x",
                channel: .ios),
            order: "-captured_at", limit: 10)
        let url = try #require(transport.requests.first?.url)
        #expect(url.path(percentEncoded: true) == "/quickr/api/v1/topics/a%20b%2Fc/entries")
        let query = try #require(url.query(percentEncoded: true))
        #expect(
            query == "order=-captured_at&limit=10&captured_from=2026-03-01T07:00:00.500000%2B00:00&version=2"
                + "&source=ios%20widget%26x&channel=ios")
    }

    @Test func listChangesUsesTheFeedTimeoutAndLimit() async throws {
        let transport = FakeTransport()
        let client = APITest.client(transport)
        _ = try await client.listChanges(after: 42)
        _ = try await client.listChanges(after: 42, options: .init(timeout: .seconds(3)))
        _ = try await client.deleteEntry(id: Self.entryId)
        #expect(transport.requests.map(\.timeout) == [.seconds(30), .seconds(3), .seconds(15)])
        #expect(transport.requests[0].url.query() == "after=42&limit=500")
    }

    @Test func archiveSendsExpectedRevisionAsAQuery() async throws {
        let transport = FakeTransport()
        let client = APITest.client(transport)
        _ = try await client.archiveTopic(ref: Self.topicId.wireString, expectedRevision: 3)
        _ = try await client.unarchiveTopic(ref: Self.topicId.wireString)
        #expect(transport.requests[0].url.query() == "expected_revision=3" && transport.requests[0].body == nil)
        #expect(transport.requests[1].url.query() == nil)
    }

    @Test func bodiesUseTheWireDateProfile() async throws {
        let transport = FakeTransport()
        _ = try await APITest.client(transport).updateEntry(
            id: Self.entryId, EntryUpdateDTO(capturedAt: Date(timeIntervalSince1970: 1_772_625_600.25)))
        let body = String(decoding: try #require(transport.requests.first?.body), as: UTF8.self)
        #expect(body == #"{"captured_at":"2026-03-04T12:00:00.250000+00:00"}"#)
    }

    @Test func transportErrorsBecomeOutcomes() async throws {
        let transport = FakeTransport()
        transport.enqueue(.failure(.timedOut(requestStarted: true)))
        transport.enqueue(.failure(.unreachable("dns")))
        let client = APITest.client(transport)
        #expect(
            try await client.deleteEntry(id: Self.entryId).outcome
                == .uncertain(.noResponse(.timedOut(requestStarted: true))))
        #expect(try await client.deleteEntry(id: Self.entryId).outcome == .retryable(.noResponse(.unreachable("dns"))))
    }

    static func matches(_ path: String, _ template: String) -> Bool {
        let parts = path.split(separator: "/")
        let pattern = template.split(separator: "/")
        return parts.count == pattern.count
            && zip(parts, pattern).allSatisfy { $1.hasPrefix("{") || $0 == $1 }
    }
}

extension APIResponse {
    /// Type-erased, so calls with different success types fit one table.
    fileprivate var erased: APIResponse<any Sendable> {
        APIResponse<any Sendable>(
            outcome: outcome.map { $0 as any Sendable }, status: status, observed: observed, expected: expected,
            body: body, bodyIsTrusted: bodyIsTrusted)
    }
}
