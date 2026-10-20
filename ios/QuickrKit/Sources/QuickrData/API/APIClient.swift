import Foundation
import QuickrCore

/// The store's server identity: `sync_state.server_id` and `epoch` (sync-protocol.md §1.4).
public protocol ServerIdentityProvider: Sendable {
    /// Nil before the store has been bootstrapped. Mutations need one; reads without one skip the
    /// header comparison (bootstrap adopts the identity from the response).
    func currentIdentity() async throws -> ServerIdentity?
}

/// A Cloudflare Access service token (PLAN §2 "Headers").
public struct AccessCredentials: Sendable, Hashable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// Where the Access headers come from (the shared Keychain in the app), per server. Nil when none
/// are configured for it, and then no Access headers are sent.
public protocol AccessCredentialsProvider: Sendable {
    /// The token for requests to `baseURL` (the request's target), so a request can only ever
    /// carry the token of the server it goes to.
    func accessCredentials(for baseURL: URL) async throws -> AccessCredentials?
}

/// A fixed identity, for tests and for callers that already hold one.
public struct StaticServerIdentity: ServerIdentityProvider {
    public var identity: ServerIdentity?

    public init(_ identity: ServerIdentity?) { self.identity = identity }

    public func currentIdentity() async throws -> ServerIdentity? { identity }
}

/// Fixed Access credentials (or none).
public struct StaticAccessCredentials: AccessCredentialsProvider {
    public var credentials: AccessCredentials?

    public init(_ credentials: AccessCredentials?) { self.credentials = credentials }

    public func accessCredentials(for baseURL: URL) async throws -> AccessCredentials? { credentials }
}

/// Per-call options.
public struct RequestOptions: Sendable, Hashable {
    /// The identity a mutation must target, instead of the provider's current one. The outbox
    /// passes the claim's (`store.server_id`, `claim_epoch`; outbox.md §4). For a read it is the
    /// identity the response is checked against.
    public var expecting: ServerIdentity?
    /// Nil uses the operation's default: 30 s for feed pages, 15 s otherwise. The outbox caps it by
    /// the remaining budget.
    public var timeout: Duration?

    public init(expecting: ServerIdentity? = nil, timeout: Duration? = nil) {
        self.expecting = expecting
        self.timeout = timeout
    }
}

/// A request the client refused to send. Network and server failures are never thrown: they are
/// `APIOutcome`s.
public enum APIClientError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A mutation without a server identity to expect: the store isn't bootstrapped.
    case noServerIdentity(operationId: String)
    case encodingFailed(operationId: String, reason: String)
    /// The identity or credentials provider threw.
    case providerFailed(String)

    public var description: String {
        switch self {
        case .noServerIdentity(let operationId): "\(operationId): no server identity to expect (store not bootstrapped)"
        case .encodingFailed(let operationId, let reason): "\(operationId): could not encode the body: \(reason)"
        case .providerFailed(let reason): "credentials or identity unavailable: \(reason)"
        }
    }
}

/// Entry filters shared by listEntries, exportEntriesCsv, getTopicStats and getQuestionSeries.
public struct EntryFilters: Sendable, Hashable {
    public var capturedFrom: Date?
    public var capturedTo: Date?
    public var version: Int?
    public var source: String?
    public var channel: Channel?

    public init(
        capturedFrom: Date? = nil, capturedTo: Date? = nil, version: Int? = nil, source: String? = nil,
        channel: Channel? = nil
    ) {
        self.capturedFrom = capturedFrom
        self.capturedTo = capturedTo
        self.version = version
        self.source = source
        self.channel = channel
    }

    var queryItems: [URLQueryItem] {
        [
            capturedFrom.map { URLQueryItem(name: "captured_from", value: WireDate.format($0)) },
            capturedTo.map { URLQueryItem(name: "captured_to", value: WireDate.format($0)) },
            version.map { URLQueryItem(name: "version", value: String($0)) },
            source.map { URLQueryItem(name: "source", value: $0) },
            channel.map { URLQueryItem(name: "channel", value: $0.rawValue) },
        ].compactMap { $0 }
    }
}

/// The typed quickR API client: one method per `operationId` (`Endpoints`), over a `Transport`.
///
/// Every request carries `Accept`, `Cache-Control: no-store`, `X-QuickR-Channel: ios` and, when
/// configured, the Access headers; a body adds `Content-Type`. Every mutation also carries
/// `X-QuickR-Expect-Server-Id` and `X-QuickR-Expect-Epoch` (F10). Every response is checked against
/// the expected identity before it is interpreted, and classified into an `APIOutcome`.
///
/// `createEntry` fills a missing `source` from `origin`, the surface the client runs in.
public struct APIClient: Sendable {
    public static let defaultTimeout: Duration = .seconds(15)
    public static let feedTimeout: Duration = .seconds(30)
    public static let feedPageLimit = 500

    public var baseURL: URL
    public var transport: any Transport
    public var identity: any ServerIdentityProvider
    public var credentials: any AccessCredentialsProvider
    public var origin: OutboxOrigin

    public init(
        baseURL: URL, transport: any Transport, identity: any ServerIdentityProvider,
        credentials: any AccessCredentialsProvider = StaticAccessCredentials(nil), origin: OutboxOrigin = .app
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.identity = identity
        self.credentials = credentials
        self.origin = origin
    }

    // MARK: Meta

    public func health(_ options: RequestOptions = .init()) async throws -> APIResponse<Health> {
        try await send(Endpoints.health, options: options)
    }

    public func listQuestionTypes(_ options: RequestOptions = .init()) async throws -> APIResponse<[QuestionTypeInfo]> {
        try await send(Endpoints.listQuestionTypes, options: options)
    }

    public func getLimits(_ options: RequestOptions = .init()) async throws -> APIResponse<Limits> {
        try await send(Endpoints.getLimits, options: options)
    }

    // MARK: Topics

    /// `status` is `active`, `archived` or `all`; `sort` one of the server's `TopicSort` values.
    public func listTopics(
        status: String? = nil, query: String? = nil, sort: String? = nil, dueOnly: Bool? = nil, limit: Int? = nil,
        offset: Int? = nil, options: RequestOptions = .init()
    ) async throws -> APIResponse<Page<TopicSummary>> {
        let items: [URLQueryItem?] = [
            query.map { URLQueryItem(name: "q", value: $0) },
            status.map { URLQueryItem(name: "status", value: $0) },
            sort.map { URLQueryItem(name: "sort", value: $0) },
            dueOnly.map { URLQueryItem(name: "due_only", value: $0 ? "true" : "false") },
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            offset.map { URLQueryItem(name: "offset", value: String($0)) },
        ]
        return try await send(Endpoints.listTopics, query: items.compactMap { $0 }, options: options)
    }

    public func createTopic(_ body: TopicCreateDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<Topic>
    {
        try await send(Endpoints.createTopic, body: body, options: options)
    }

    /// `ref` is a topic id or slug.
    public func getTopic(ref: String, options: RequestOptions = .init()) async throws -> APIResponse<Topic> {
        try await send(Endpoints.getTopic, path: ["ref": ref], options: options)
    }

    public func updateTopic(ref: String, _ body: TopicUpdateDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<Topic>
    {
        try await send(Endpoints.updateTopic, path: ["ref": ref], body: body, options: options)
    }

    public func deleteTopic(ref: String, options: RequestOptions = .init()) async throws -> APIResponse<EmptyBody> {
        try await send(Endpoints.deleteTopic, path: ["ref": ref], options: options)
    }

    public func archiveTopic(ref: String, expectedRevision: Int? = nil, options: RequestOptions = .init())
        async throws -> APIResponse<Topic>
    {
        try await send(
            Endpoints.archiveTopic, path: ["ref": ref], query: Self.expectedRevision(expectedRevision),
            options: options)
    }

    public func unarchiveTopic(ref: String, expectedRevision: Int? = nil, options: RequestOptions = .init())
        async throws -> APIResponse<Topic>
    {
        try await send(
            Endpoints.unarchiveTopic, path: ["ref": ref], query: Self.expectedRevision(expectedRevision),
            options: options)
    }

    // MARK: Versions

    public func listTopicVersions(ref: String, options: RequestOptions = .init()) async throws
        -> APIResponse<[TopicVersion]>
    {
        try await send(Endpoints.listTopicVersions, path: ["ref": ref], options: options)
    }

    public func publishTopicVersion(ref: String, _ body: VersionCreateDTO, options: RequestOptions = .init())
        async throws -> APIResponse<Topic>
    {
        try await send(Endpoints.publishTopicVersion, path: ["ref": ref], body: body, options: options)
    }

    public func checkTopicVersion(ref: String, _ body: VersionDraftDTO, options: RequestOptions = .init())
        async throws -> APIResponse<CompatibilityReport>
    {
        try await send(Endpoints.checkTopicVersion, path: ["ref": ref], body: body, options: options)
    }

    // MARK: Entries

    /// `order` is one of the server's `EntryOrder` values (`-captured_at` by default).
    public func listEntries(
        ref: String, filters: EntryFilters = .init(), order: String? = nil, limit: Int? = nil, offset: Int? = nil,
        options: RequestOptions = .init()
    ) async throws -> APIResponse<Page<Entry>> {
        let items: [URLQueryItem?] = [
            order.map { URLQueryItem(name: "order", value: $0) },
            limit.map { URLQueryItem(name: "limit", value: String($0)) },
            offset.map { URLQueryItem(name: "offset", value: String($0)) },
        ]
        return try await send(
            Endpoints.listEntries, path: ["ref": ref], query: items.compactMap { $0 } + filters.queryItems,
            options: options)
    }

    /// `ref` is the topic id (the outbox never addresses a topic by slug). A nil `body.source`
    /// becomes the client's `origin.source`.
    public func createEntry(ref: String, _ body: EntryCreateDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<Entry>
    {
        var body = body
        if body.source == nil { body.source = origin.source }
        return try await send(Endpoints.createEntry, path: ["ref": ref], body: body, options: options)
    }

    /// The CSV bytes. A 2xx that isn't `text/csv` (a captive portal) is `uncertain`.
    public func exportEntriesCsv(ref: String, filters: EntryFilters = .init(), options: RequestOptions = .init())
        async throws -> APIResponse<Data>
    {
        try await send(Endpoints.exportEntriesCsv, path: ["ref": ref], query: filters.queryItems, options: options)
    }

    public func getEntry(id: UUID, options: RequestOptions = .init()) async throws -> APIResponse<Entry> {
        try await send(Endpoints.getEntry, path: ["entry_id": id.wireString], options: options)
    }

    public func updateEntry(id: UUID, _ body: EntryUpdateDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<Entry>
    {
        try await send(Endpoints.updateEntry, path: ["entry_id": id.wireString], body: body, options: options)
    }

    public func deleteEntry(id: UUID, options: RequestOptions = .init()) async throws -> APIResponse<EmptyBody> {
        try await send(Endpoints.deleteEntry, path: ["entry_id": id.wireString], options: options)
    }

    // MARK: Feed

    /// One feed page (sync-protocol.md §1.1): 30 s timeout unless `options` says otherwise.
    public func listChanges(after cursor: Int, limit: Int = feedPageLimit, options: RequestOptions = .init())
        async throws -> APIResponse<ChangePage>
    {
        var options = options
        options.timeout = options.timeout ?? Self.feedTimeout
        return try await send(
            Endpoints.listChanges,
            query: [
                URLQueryItem(name: "after", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit)),
            ],
            options: options)
    }

    // MARK: Stats

    public func getTopicStats(ref: String, filters: EntryFilters = .init(), options: RequestOptions = .init())
        async throws -> APIResponse<TopicStats>
    {
        try await send(Endpoints.getTopicStats, path: ["ref": ref], query: filters.queryItems, options: options)
    }

    /// `timezone` is an IANA name for bucketing (the server defaults to UTC).
    public func getQuestionSeries(
        ref: String, key: String, bucket: QuestionSeries.Bucket? = nil, timezone: String? = nil,
        filters: EntryFilters = .init(), options: RequestOptions = .init()
    ) async throws -> APIResponse<QuestionSeries> {
        let items: [URLQueryItem?] = [
            bucket.map { URLQueryItem(name: "bucket", value: $0.rawValue) },
            timezone.map { URLQueryItem(name: "tz", value: $0) },
        ]
        return try await send(
            Endpoints.getQuestionSeries, path: ["ref": ref, "key": key],
            query: items.compactMap { $0 } + filters.queryItems, options: options)
    }

    // MARK: Push

    public func getPushConfig(_ options: RequestOptions = .init()) async throws -> APIResponse<PushConfig> {
        try await send(Endpoints.getPushConfig, options: options)
    }

    public func createPushSubscription(_ body: PushSubscriptionInDTO, options: RequestOptions = .init())
        async throws -> APIResponse<PushSubscription>
    {
        try await send(Endpoints.createPushSubscription, body: body, options: options)
    }

    public func deletePushSubscription(_ body: PushSubscriptionDeleteDTO, options: RequestOptions = .init())
        async throws -> APIResponse<EmptyBody>
    {
        try await send(Endpoints.deletePushSubscription, body: body, options: options)
    }

    public func sendTestPush(_ options: RequestOptions = .init()) async throws -> APIResponse<PushTestResult> {
        try await send(Endpoints.sendTestPush, options: options)
    }

    public func registerApnsDevice(_ body: ApnsDeviceInDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<ApnsDevice>
    {
        try await send(Endpoints.registerApnsDevice, body: body, options: options)
    }

    public func deleteApnsDevice(_ body: ApnsDeviceRefDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<EmptyBody>
    {
        try await send(Endpoints.deleteApnsDevice, body: body, options: options)
    }

    public func sendApnsTestPush(_ body: ApnsDeviceRefDTO, options: RequestOptions = .init()) async throws
        -> APIResponse<PushTestResult>
    {
        try await send(Endpoints.sendApnsTestPush, body: body, options: options)
    }

    // MARK: Core

    /// Builds, sends and classifies one call. Throws only `APIClientError`.
    public func send<Body, Response>(
        _ endpoint: Endpoint<Body, Response>, path parameters: [String: String] = [:], query: [URLQueryItem] = [],
        body: Body? = nil, options: RequestOptions = .init()
    ) async throws -> APIResponse<Response.Domain> {
        let expected = try await expectedIdentity(options)
        let request = try await build(
            endpoint, path: parameters, query: query, body: body, options: options, expected: expected)
        let result: Result<HTTPResponse, TransportError>
        do {
            result = .success(try await transport.send(request))
        } catch let error as TransportError {
            result = .failure(error)
        } catch {
            result = .failure(.failed(String(describing: error), requestStarted: true))
        }
        return APIClassifier.classify(result, expected: expected) { response in
            if Response.self == CSVBody.self {
                let type = response.headers["Content-Type"]?.lowercased() ?? ""
                guard type.hasPrefix("text/csv") else { throw ContractError.invalid("not text/csv: \(type)") }
            }
            return try Response.decode(response.body, using: WireCoding.decoder()).toDomain()
        }
    }

    /// The request `send` would make, without sending it. Throws only `APIClientError`.
    public func request<Body, Response>(
        _ endpoint: Endpoint<Body, Response>, path parameters: [String: String] = [:], query: [URLQueryItem] = [],
        body: Body? = nil, options: RequestOptions = .init()
    ) async throws -> HTTPRequest {
        try await build(
            endpoint, path: parameters, query: query, body: body, options: options,
            expected: try await expectedIdentity(options))
    }

    private func expectedIdentity(_ options: RequestOptions) async throws -> ServerIdentity? {
        if let override = options.expecting { return override }
        do {
            return try await identity.currentIdentity()
        } catch {
            throw APIClientError.providerFailed(String(describing: error))
        }
    }

    private func build<Body, Response>(
        _ endpoint: Endpoint<Body, Response>, path parameters: [String: String], query: [URLQueryItem], body: Body?,
        options: RequestOptions, expected: ServerIdentity?
    ) async throws -> HTTPRequest {
        var headers: HTTPHeaders = [
            "Accept": Response.self == CSVBody.self ? "text/csv" : "application/json",
            "Cache-Control": "no-store",
            QuickrHeader.channel: Channel.ios.rawValue,
        ]
        let access: AccessCredentials?
        do {
            access = try await credentials.accessCredentials(for: baseURL)
        } catch {
            throw APIClientError.providerFailed(String(describing: error))
        }
        if let access {
            headers[QuickrHeader.cfAccessClientId] = access.clientId
            headers[QuickrHeader.cfAccessClientSecret] = access.clientSecret
        }
        if endpoint.isMutation {
            guard let expected else { throw APIClientError.noServerIdentity(operationId: endpoint.operationId) }
            headers[QuickrHeader.expectServerId] = expected.serverId
            headers[QuickrHeader.expectEpoch] = expected.epoch
        }

        var data: Data?
        if let body, Body.self != EmptyBody.self {
            do {
                data = try WireCoding.encoder().encode(body)
            } catch {
                throw APIClientError.encodingFailed(
                    operationId: endpoint.operationId, reason: String(describing: error))
            }
            headers["Content-Type"] = "application/json"
        }
        return HTTPRequest(
            method: endpoint.method, url: url(endpoint.path(parameters), query: query), headers: headers, body: data,
            timeout: options.timeout ?? Self.defaultTimeout)
    }

    static func expectedRevision(_ revision: Int?) -> [URLQueryItem] {
        revision.map { [URLQueryItem(name: "expected_revision", value: String($0))] } ?? []
    }

    /// `baseURL` (which may have a path prefix) + the percent-encoded `path` + `query`. A `+` in a
    /// query value (an offset in a date) is encoded, so the server never reads it as a space.
    func url(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let prefix =
            components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = prefix + path
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { preconditionFailure("invalid URL from \(baseURL) and \(path)") }
        return url
    }
}
