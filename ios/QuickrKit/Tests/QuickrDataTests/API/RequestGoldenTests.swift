import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// B5 request goldens (PLAN §2 "API client"): what the Swift client puts on the wire for every
/// mutating or request-bodied operation, in `shared/fixtures/requests/<operationId>[.<variant>].json`.
/// `backend/tests/test_request_goldens.py` validates each body against the Pydantic request
/// models and replays it through the app.
///
/// Each golden is built by the real `APIClient` (headers, path, query, `WireCoding` body) and
/// captured from a `FakeTransport`. With `QUICKR_UPDATE_VECTORS=1` the files are rewritten (stale
/// ones removed); otherwise they must match.
@Suite(.timeLimit(.minutes(5))) struct RequestGoldenTests {
    /// Placeholders the pytest replay swaps for real values.
    static let identity = ServerIdentity(
        serverId: "11111111-1111-4111-8111-111111111111", epoch: "22222222-2222-4222-8222-222222222222")
    static let topicId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let entryIds = (1...3).map { UUID(uuidString: String(format: "44444444-4444-4444-8444-%012d", $0))! }
    static let apnsToken = "7c5d0e1fa2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d"
    static let pushEndpoint = "https://web.push.apple.com/QGuQyavXutnMlB5k"

    static let directory = Fixtures.root.appendingPathComponent("requests", isDirectory: true)

    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var origin: OutboxOrigin = .app
        var call: @Sendable (APIClient) async throws -> Void

        var description: String { name }
        var operationId: String { String(name.prefix { $0 != "." }) }
    }

    static let everything: [Question] = [
        Question(key: "glasses", label: "Glasses of water", kind: .int(.init(min: 0, max: 30, unit: "glasses"))),
        Question(
            key: "hours", label: "Hours slept", helpText: "Time actually asleep.",
            kind: .double(.init(min: 0, max: 24, decimals: 1, unit: "h"))),
        Question(
            key: "mood", label: "Mood",
            kind: .choice(
                .init(options: [
                    EnumOption(value: "great", label: "Great"), EnumOption(value: "ok", label: "OK"),
                    EnumOption(value: "poor", label: "Poor"),
                ]))),
        Question(
            key: "factors", label: "Factors", required: false,
            kind: .choice(
                .init(
                    options: [
                        EnumOption(value: "caffeine", label: "Caffeine"),
                        EnumOption(value: "screens", label: "Screens"),
                        EnumOption(value: "exercise", label: "Exercise"),
                    ], multiple: true, minSelected: 1, maxSelected: 2))),
        Question(key: "note", label: "Note", required: false, kind: .string(.init(maxLength: 280, multiline: true))),
    ]

    /// v2: the "poor" mood option is retired.
    static var everythingV2: [Question] {
        var questions = everything
        if case .choice(var rules) = questions[2].kind {
            rules.options[2].archived = true
            questions[2].kind = .choice(rules)
        }
        return questions
    }

    static let daily = Schedule.daily(
        .init(times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 21, minute: 30)], timezone: "Europe/London"))

    static func date(_ text: String) -> Date { WireDate.parse(text)! }

    static let cases: [Case] = [
        // Topics
        Case(name: "createTopic") { client in
            _ = try await client.createTopic(
                TopicCreateDTO(
                    name: "Everything", description: "One of each question type.", questions: everything,
                    schedule: daily))
        },
        Case(name: "createTopic.interval") { client in
            _ = try await client.createTopic(
                TopicCreateDTO(
                    name: "Water", slug: "water",
                    questions: [Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20)))],
                    schedule: .interval(.init(everyMinutes: 180, timezone: "Europe/London", notify: false))))
        },
        Case(name: "updateTopic") { client in
            _ = try await client.updateTopic(
                ref: topicId.wireString,
                TopicUpdateDTO(name: "Everything else", description: "Renamed.", expectedRevision: 1))
        },
        Case(name: "updateTopic.schedule_set") { client in
            _ = try await client.updateTopic(
                ref: topicId.wireString,
                TopicUpdateDTO(
                    schedule: .value(ScheduleInputDTO(.interval(.init(everyMinutes: 90, timezone: "UTC")))),
                    expectedRevision: 1))
        },
        Case(name: "updateTopic.schedule_cleared") { client in
            _ = try await client.updateTopic(ref: topicId.wireString, TopicUpdateDTO(schedule: .null))
        },
        Case(name: "archiveTopic") { client in
            _ = try await client.archiveTopic(ref: topicId.wireString, expectedRevision: 1)
        },
        Case(name: "unarchiveTopic") { client in
            _ = try await client.unarchiveTopic(ref: topicId.wireString, expectedRevision: 2)
        },
        Case(name: "deleteTopic") { client in
            _ = try await client.deleteTopic(ref: topicId.wireString)
        },
        // Versions
        Case(name: "publishTopicVersion") { client in
            _ = try await client.publishTopicVersion(
                ref: topicId.wireString,
                VersionCreateDTO(
                    questions: everythingV2, baseVersion: 1,
                    timer: TopicTimer(steps: [.init(key: "pour", label: "Pour"), .init(key: "drink", label: "Drink")]),
                    changeNote: "Retire 'poor'"))
        },
        Case(name: "checkTopicVersion") { client in
            _ = try await client.checkTopicVersion(
                ref: topicId.wireString, VersionDraftDTO(questions: Array(everythingV2.prefix(3)), baseVersion: 1))
        },
        // Entries: the outbox's shapes (outbox.md §1)
        Case(name: "createEntry") { client in
            _ = try await client.createEntry(
                ref: topicId.wireString,
                EntryCreateDTO(
                    id: entryIds[0],
                    answers: [
                        "glasses": .int(6), "hours": .double(7.5), "mood": .string("great"),
                        "factors": .strings(["caffeine", "exercise"]), "note": .string("Slept well. \"Really\" 😴"),
                    ],
                    source: nil, capturedAt: date("2026-03-01T08:05:00.25Z"), notes: "Weekend.",
                    meta: ["device": "iphone"], version: 1))
        },
        Case(name: "createEntry.widget", origin: .widget) { client in
            _ = try await client.createEntry(
                ref: topicId.wireString,
                EntryCreateDTO(
                    id: entryIds[1], answers: ["glasses": .int(3), "hours": .double(6), "mood": .string("ok")],
                    source: nil, capturedAt: date("2026-03-02T07:55:00+01:00"), version: 1))
        },
        Case(name: "createEntry.notification", origin: .notification) { client in
            _ = try await client.createEntry(
                ref: topicId.wireString,
                EntryCreateDTO(
                    id: entryIds[2], answers: ["glasses": .int(1), "hours": .double(8.25), "mood": .string("poor")],
                    source: nil, capturedAt: date("2026-03-03T21:30:00Z"), version: 1))
        },
        Case(name: "updateEntry") { client in
            _ = try await client.updateEntry(
                id: entryIds[0],
                EntryUpdateDTO(
                    answers: ["glasses": .int(7), "note": nil, "factors": .strings(["screens"])], notes: "Edited.",
                    expectedRevision: 1))
        },
        Case(name: "updateEntry.captured_at") { client in
            _ = try await client.updateEntry(
                id: entryIds[0],
                EntryUpdateDTO(capturedAt: date("2026-03-01T09:00:00.000001Z"), meta: [:], expectedRevision: 1))
        },
        Case(name: "deleteEntry") { client in
            _ = try await client.deleteEntry(id: entryIds[0])
        },
        // Push
        Case(name: "createPushSubscription") { client in
            let json =
                #"{"endpoint": "\#(pushEndpoint)", "keys": {"p256dh": "BOr8uW3hZ8t3Qn0dJ4Xq-key", "auth": "x5sQe1Zl0dAuth"}, "user_agent": "quickR iOS"}"#
            let body = try WireCoding.decoder().decode(PushSubscriptionInDTO.self, from: Data(json.utf8))
            _ = try await client.createPushSubscription(body)
        },
        Case(name: "deletePushSubscription") { client in
            let body = try WireCoding.decoder().decode(
                PushSubscriptionDeleteDTO.self, from: Data(#"{"endpoint": "\#(pushEndpoint)"}"#.utf8))
            _ = try await client.deletePushSubscription(body)
        },
        Case(name: "sendTestPush") { client in
            _ = try await client.sendTestPush()
        },
        Case(name: "registerApnsDevice") { client in
            _ = try await client.registerApnsDevice(
                ApnsDeviceInDTO(
                    token: apnsToken, environment: .sandbox, bundleId: "com.bahumia.quickr", appVersion: "1.0 (1)",
                    deviceName: "iPhone"))
        },
        Case(name: "deleteApnsDevice") { client in
            _ = try await client.deleteApnsDevice(ApnsDeviceRefDTO(token: apnsToken))
        },
        Case(name: "sendApnsTestPush") { client in
            _ = try await client.sendApnsTestPush(ApnsDeviceRefDTO(token: apnsToken))
        },
    ]

    /// The golden file for one case: `{operation_id, request: {method, path, headers, body}}`.
    static func render(_ testCase: Case) async throws -> String {
        let transport = FakeTransport()
        transport.enqueue(.failure(.unreachable("golden capture")))
        let client = APIClient(
            baseURL: URL(string: "https://quickr.test")!, transport: transport,
            identity: StaticServerIdentity(identity), origin: testCase.origin)
        try await testCase.call(client)
        let request = try #require(transport.requests.only)
        let target =
            request.url.path(percentEncoded: true) + (request.url.query(percentEncoded: true).map { "?" + $0 } ?? "")
        let body: Any = try request.body.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let golden: [String: Any] = [
            "operation_id": testCase.operationId,
            "request": [
                "method": request.method.rawValue, "path": target, "headers": request.headers.all, "body": body,
            ] as [String: Any],
        ]
        return CanonicalJSON.render(golden)
    }

    @Test func goldensMatchCommitted() async throws {
        var rendered: [String: String] = [:]
        for testCase in Self.cases {
            #expect(rendered.updateValue(try await Self.render(testCase), forKey: testCase.name + ".json") == nil)
        }
        let updating = ProcessInfo.processInfo.environment["QUICKR_UPDATE_VECTORS"] == "1"
        let manager = FileManager.default
        let existing = Set((try? manager.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
        if updating {
            try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for stale in existing.subtracting(rendered.keys) {
                try manager.removeItem(at: Self.directory.appendingPathComponent(stale))
            }
            for (name, content) in rendered {
                try Data(content.utf8).write(to: Self.directory.appendingPathComponent(name))
            }
            return
        }
        let stale = "shared/fixtures/requests is stale - run QUICKR_UPDATE_VECTORS=1 swift test --filter RequestGolden"
        #expect(existing == Set(rendered.keys), "\(stale)")
        for (name, content) in rendered.sorted(by: { $0.key < $1.key }) {
            let committed = try? String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
            #expect(committed == content, "\(name): \(stale)")
        }
    }

    /// G1 for requests (PLAN §6a rule 12): every mutation and every operation with a body has at
    /// least one golden, and every golden names a known operation.
    @Test func everyMutationAndBodiedOperationHasAGolden() {
        let covered = Set(Self.cases.map(\.operationId))
        for endpoint in Endpoints.all where endpoint.isMutation || endpoint.hasRequestBody {
            #expect(covered.contains(endpoint.operationId), "no request golden for \(endpoint.operationId)")
        }
        for operationId in covered {
            #expect(Endpoints.named(operationId) != nil, "unknown operation \(operationId)")
        }
    }

    /// Every golden body decodes back into its request DTO, and its path fits the endpoint.
    @Test(arguments: cases)
    func goldenRoundTrips(_ testCase: Case) async throws {
        let json = try await Self.render(testCase)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let request = try #require(object["request"] as? [String: Any])
        let endpoint = try #require(Endpoints.named(testCase.operationId))
        #expect(request["method"] as? String == endpoint.method.rawValue)
        let headers = try #require(request["headers"] as? [String: String])
        #expect(headers["x-quickr-channel"] == "ios")
        #expect((headers["x-quickr-expect-epoch"] != nil) == endpoint.isMutation)
        if let body = request["body"], !(body is NSNull) {
            #expect(endpoint.hasRequestBody)
            #expect(headers["content-type"] == "application/json")
            _ = try endpoint.decodeRequestBody(try JSONSerialization.data(withJSONObject: body))
        } else {
            #expect(!endpoint.hasRequestBody)
        }
    }

    @Test func canonicalJSONMatchesPythonDumps() throws {
        let data = Data(#"{"b": [1, 2.5, 3.0, true, null, {}], "a": "é\n\"", "c": []}"#.utf8)
        #expect(
            try CanonicalJSON.render(data: data)
                == "{\n  \"a\": \"é\\n\\\"\",\n  \"b\": [\n    1,\n    2.5,\n    3.0,\n    true,\n    null,\n    {}\n  ],\n  \"c\": []\n}\n"
        )
    }
}

extension Array {
    /// The single element, or nil.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
