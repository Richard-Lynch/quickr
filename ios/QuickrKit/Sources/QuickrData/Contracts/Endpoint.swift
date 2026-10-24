import Foundation
import QuickrCore

public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One API operation, keyed by its `operationId` in `openapi.json`.
///
/// `pathTemplate` has `{name}` placeholders and no query; the API client adds query items.
/// `isMutation` operations carry the F10 precondition headers (sync-protocol.md §1.4).
public struct Endpoint<RequestBody: Codable & Sendable, Response: WireResponse>: Sendable {
    public let operationId: String
    public let method: HTTPMethod
    public let pathTemplate: String
    public let isMutation: Bool

    public init(_ operationId: String, _ method: HTTPMethod, _ pathTemplate: String, mutation: Bool? = nil) {
        self.operationId = operationId
        self.method = method
        self.pathTemplate = pathTemplate
        self.isMutation = mutation ?? (method != .get)
    }

    /// The path with every `{name}` replaced by its percent-encoded value. Traps on a missing
    /// parameter, which is a programming error.
    public func path(_ parameters: [String: String] = [:]) -> String {
        var path = pathTemplate
        for name in Self.placeholders(in: pathTemplate) {
            guard let value = parameters[name] else { preconditionFailure("\(operationId): missing {\(name)}") }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? value
            path = path.replacingOccurrences(of: "{\(name)}", with: encoded)
        }
        return path
    }

    public var erased: AnyEndpoint {
        AnyEndpoint(
            operationId: operationId, method: method, pathTemplate: pathTemplate, isMutation: isMutation,
            hasRequestBody: RequestBody.self != EmptyBody.self,
            responseType: Response.self,
            decodeRequestBody: { data in try WireCoding.decoder().decode(RequestBody.self, from: data) },
            decodeResponse: { data in try Response.decode(data, using: WireCoding.decoder()).toDomain() })
    }

    static func placeholders(in template: String) -> [String] {
        template.split(separator: "{").dropFirst().compactMap { $0.split(separator: "}").first.map(String.init) }
    }
}

/// An `Endpoint` with its types erased, for tables and coverage checks.
public struct AnyEndpoint: Sendable {
    public let operationId: String
    public let method: HTTPMethod
    public let pathTemplate: String
    public let isMutation: Bool
    public let hasRequestBody: Bool
    public let responseType: any WireResponse.Type
    /// Decodes a request body into `RequestBody` (for golden and fixture checks).
    public let decodeRequestBody: @Sendable (Data) throws -> any Sendable
    /// Decodes a success body and maps it to its domain model.
    public let decodeResponse: @Sendable (Data) throws -> any Sendable

    /// Whether the success response is JSON (or empty). Only `exportEntriesCsv` isn't.
    public var hasJSONResponse: Bool { responseType != CSVBody.self }
}

/// Every operation the iOS client knows, by `operationId` (sync-protocol.md §13.2 G1).
public enum Endpoints {
    public static let health = Endpoint<EmptyBody, HealthDTO>("health", .get, "/api/v1/health")
    public static let listQuestionTypes = Endpoint<EmptyBody, [QuestionTypeInfoDTO]>(
        "listQuestionTypes", .get, "/api/v1/question-types")
    public static let getLimits = Endpoint<EmptyBody, LimitsDTO>("getLimits", .get, "/api/v1/limits")

    public static let listTopics = Endpoint<EmptyBody, PageDTO<TopicSummaryDTO>>("listTopics", .get, "/api/v1/topics")
    public static let createTopic = Endpoint<TopicCreateDTO, TopicDetailDTO>("createTopic", .post, "/api/v1/topics")
    public static let getTopic = Endpoint<EmptyBody, TopicDetailDTO>("getTopic", .get, "/api/v1/topics/{ref}")
    public static let updateTopic = Endpoint<TopicUpdateDTO, TopicDetailDTO>(
        "updateTopic", .patch, "/api/v1/topics/{ref}")
    public static let deleteTopic = Endpoint<EmptyBody, EmptyBody>("deleteTopic", .delete, "/api/v1/topics/{ref}")
    /// Query `expected_revision` (outbox.md §1).
    public static let archiveTopic = Endpoint<EmptyBody, TopicDetailDTO>(
        "archiveTopic", .post, "/api/v1/topics/{ref}/archive")
    /// Query `expected_revision` (outbox.md §1).
    public static let unarchiveTopic = Endpoint<EmptyBody, TopicDetailDTO>(
        "unarchiveTopic", .post, "/api/v1/topics/{ref}/unarchive")

    public static let listTopicVersions = Endpoint<EmptyBody, [TopicVersionDTO]>(
        "listTopicVersions", .get, "/api/v1/topics/{ref}/versions")
    public static let publishTopicVersion = Endpoint<VersionCreateDTO, TopicDetailDTO>(
        "publishTopicVersion", .post, "/api/v1/topics/{ref}/versions")
    /// A POST that changes nothing: no precondition headers.
    public static let checkTopicVersion = Endpoint<VersionDraftDTO, CompatibilityReportDTO>(
        "checkTopicVersion", .post, "/api/v1/topics/{ref}/versions/check", mutation: false)

    public static let listEntries = Endpoint<EmptyBody, PageDTO<EntryDTO>>(
        "listEntries", .get, "/api/v1/topics/{ref}/entries")
    public static let createEntry = Endpoint<EntryCreateDTO, EntryDTO>(
        "createEntry", .post, "/api/v1/topics/{ref}/entries")
    public static let exportEntriesCsv = Endpoint<EmptyBody, CSVBody>(
        "exportEntriesCsv", .get, "/api/v1/topics/{ref}/entries.csv")
    public static let getEntry = Endpoint<EmptyBody, EntryDTO>("getEntry", .get, "/api/v1/entries/{entry_id}")
    public static let updateEntry = Endpoint<EntryUpdateDTO, EntryDTO>(
        "updateEntry", .patch, "/api/v1/entries/{entry_id}")
    public static let deleteEntry = Endpoint<EmptyBody, EmptyBody>("deleteEntry", .delete, "/api/v1/entries/{entry_id}")

    /// Every tap on a run of a timed topic (timers.md §3.2).
    public static let recordRunEvent = Endpoint<RunEventInDTO, RunEventResultDTO>(
        "recordRunEvent", .post, "/api/v1/runs/{run_id}/events")
    /// An alias returns the run it was merged into.
    public static let getRun = Endpoint<EmptyBody, RunDTO>("getRun", .get, "/api/v1/runs/{run_id}")
    /// Query `status` (`open`, `finishing`; repeatable) and `topic`.
    public static let listRuns = Endpoint<EmptyBody, [RunDTO]>("listRuns", .get, "/api/v1/runs")

    /// Query `after` and `limit` (sync-protocol.md §1.1).
    public static let listChanges = Endpoint<EmptyBody, ChangePageDTO>("listChanges", .get, "/api/v1/changes")

    public static let getTopicStats = Endpoint<EmptyBody, TopicStatsDTO>(
        "getTopicStats", .get, "/api/v1/topics/{ref}/stats")
    public static let getQuestionSeries = Endpoint<EmptyBody, QuestionSeriesDTO>(
        "getQuestionSeries", .get, "/api/v1/topics/{ref}/questions/{key}/series")

    public static let getPushConfig = Endpoint<EmptyBody, PushConfigDTO>("getPushConfig", .get, "/api/v1/push/config")
    public static let createPushSubscription = Endpoint<PushSubscriptionInDTO, PushSubscriptionDTO>(
        "createPushSubscription", .post, "/api/v1/push/subscriptions")
    public static let deletePushSubscription = Endpoint<PushSubscriptionDeleteDTO, EmptyBody>(
        "deletePushSubscription", .post, "/api/v1/push/subscriptions/delete")
    public static let sendTestPush = Endpoint<EmptyBody, PushTestResultDTO>("sendTestPush", .post, "/api/v1/push/test")

    /// Upsert of this device's token (notifications.md §9.2). App process only.
    public static let registerApnsDevice = Endpoint<ApnsDeviceInDTO, ApnsDeviceDTO>(
        "registerApnsDevice", .post, "/api/v1/push/apns/devices")
    public static let deleteApnsDevice = Endpoint<ApnsDeviceRefDTO, EmptyBody>(
        "deleteApnsDevice", .post, "/api/v1/push/apns/devices/delete")
    /// "Test this device". Online only.
    public static let sendApnsTestPush = Endpoint<ApnsDeviceRefDTO, PushTestResultDTO>(
        "sendApnsTestPush", .post, "/api/v1/push/apns/devices/test")

    public static let all: [AnyEndpoint] = [
        health.erased, listQuestionTypes.erased, getLimits.erased, listTopics.erased, createTopic.erased,
        getTopic.erased, updateTopic.erased, deleteTopic.erased, archiveTopic.erased, unarchiveTopic.erased,
        listTopicVersions.erased, publishTopicVersion.erased, checkTopicVersion.erased, listEntries.erased,
        createEntry.erased, exportEntriesCsv.erased, getEntry.erased, updateEntry.erased, deleteEntry.erased,
        recordRunEvent.erased, getRun.erased, listRuns.erased, listChanges.erased, getTopicStats.erased,
        getQuestionSeries.erased, getPushConfig.erased,
        createPushSubscription.erased, deletePushSubscription.erased, sendTestPush.erased,
        registerApnsDevice.erased, deleteApnsDevice.erased, sendApnsTestPush.erased,
    ]

    public static func named(_ operationId: String) -> AnyEndpoint? {
        all.first { $0.operationId == operationId }
    }

    /// Decodes an error body (any non-2xx with a JSON body) into a `Problem`.
    public static func decodeProblem(_ data: Data) throws -> Problem {
        try ProblemDTO.decode(data, using: WireCoding.decoder()).toDomain()
    }
}

extension CharacterSet {
    /// RFC 3986 `pchar` minus `/`, so a slug or id can never add a path segment.
    static let urlPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()
}
