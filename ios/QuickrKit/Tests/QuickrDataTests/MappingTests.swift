import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

private func decode<Response: WireResponse>(_ type: Response.Type, _ name: String) throws -> Response.Domain {
    let fixture = try Fixtures.api(name)
    return try Response.decode(try #require(fixture.body), using: WireCoding.decoder()).toDomain()
}

private func date(_ text: String) throws -> Date { try #require(WireDate.parse(text)) }

@Suite(.timeLimit(.minutes(5))) struct MappingTests {
    @Test func topicDetailMapsEveryQuestionKind() throws {
        let topic = try decode(TopicDetailDTO.self, "getTopic")
        #expect(topic.slug == "everything")
        #expect(topic.id == UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        #expect(topic.questions.map(\.type) == [.int, .double, .enum, .enum, .str])
        #expect(topic.questions[0].kind == .int(.init(min: 0, max: 30, unit: "glasses")))
        #expect(topic.questions[1].kind == .double(.init(min: 0, max: 24, decimals: 1, unit: "h")))
        #expect(topic.questions[1].helpText == "Time actually asleep.")
        guard case .choice(let mood) = topic.questions[2].kind, case .choice(let factors) = topic.questions[3].kind
        else {
            Issue.record("expected choice questions")
            return
        }
        #expect(!mood.multiple && mood.options.count == 3 && mood.options[2].archived)
        #expect(mood.activeOptions.map(\.value) == ["great", "ok"])
        #expect(factors.multiple && factors.minSelected == 1 && factors.maxSelected == 2)
        #expect(topic.questions[3].required == false)
        #expect(topic.questions[4].kind == .string(.init(minLength: 0, maxLength: 280, multiline: true)))
        #expect(
            topic.schedule
                == .daily(
                    .init(
                        times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 21, minute: 30)],
                        days: [1, 2, 3, 4, 5, 6, 7], timezone: "Europe/London", notify: true)))
        #expect(topic.due?.isDue == true)
        #expect(topic.due?.dueSince == (try date("2026-03-04T08:00:00Z")))
        #expect(topic.revision == 2)
    }

    @Test func intervalScheduleAndNullDue() throws {
        let water = try decode(TopicDetailDTO.self, "getTopic.interval")
        #expect(water.schedule == .interval(.init(everyMinutes: 180, timezone: "Europe/London", notify: false)))
        let page = try decode(ChangePageDTO.self, "listChanges.bootstrap")
        let archived = page.items.compactMap { item -> Topic? in
            if case .topic(_, let topic) = item, topic.status == .archived { return topic }
            return nil
        }
        #expect(archived.count == 1)
        #expect(archived.first?.schedule == nil && archived.first?.due == nil)
        #expect(archived.first?.archivedAt != nil)
    }

    @Test func entryAnswersMapByKey() throws {
        let entry = try decode(EntryDTO.self, "createEntry")
        #expect(entry.id == UUID(uuidString: "0f1e2d3c-4b5a-4968-8778-000000000001"))
        #expect(entry.channel == .api)
        #expect(entry.source == "ios")
        #expect(entry.meta == ["device": "iphone"])
        #expect(
            entry.answers == [
                "glasses": .int(6), "hours": .double(7.5), "mood": .string("great"),
                "factors": .strings(["caffeine", "exercise"]), "note": .string("Slept well."),
            ])
        #expect(entry.capturedAt == (try date("2026-03-01T08:05:00Z")))
    }

    @Test func bootstrapPageMapsAllKinds() throws {
        let page = try decode(ChangePageDTO.self, "listChanges.bootstrap")
        #expect(page.serverId == "00000000-0000-4000-8000-000000000009")
        #expect(page.epoch == "00000000-0000-4000-8000-000000000008")
        #expect(page.head == 16 && page.next == 16 && !page.hasMore)
        var topics = 0
        var versions = 0
        var entries = 0
        for item in page.items {
            switch item {
            case .topic: topics += 1
            case .version(_, _, let topicId, let version):
                versions += 1
                #expect(version.version >= 1)
                #expect(topicId.uuidString.hasPrefix("00000000"))
            case .entry: entries += 1
            }
        }
        #expect((topics, versions, entries) == (3, 4, 5))
        #expect(page.items.map(\.seq) == [3, 9, 15, 2, 4, 6, 10, 7, 11, 12, 13, 16])
        #expect(page.deleted.isEmpty)
    }

    @Test func deletionPages() throws {
        let entryPage = try decode(ChangePageDTO.self, "listChanges.deletion")
        #expect(entryPage.items.isEmpty)
        #expect(entryPage.deleted.map(\.kind) == [.entry])
        #expect(entryPage.deleted.first?.seq == 17)
        let topicPage = try decode(ChangePageDTO.self, "listChanges.topic_deletion")
        let deletion = try #require(topicPage.deleted.first)
        #expect(deletion.kind == .topic && deletion.id == deletion.topicId)
    }

    /// Run items and deletions decode, then drop until the store keeps them (I-SYNC).
    @Test func runPagesDecodeAndSkipRuns() throws {
        let fixture = try Fixtures.api("listChanges.run")
        let wire = try ChangePageDTO.decode(try #require(fixture.body), using: WireCoding.decoder())
        guard case .run(_, let run) = try #require(wire.items.first) else {
            Issue.record("expected a run item")
            return
        }
        #expect(run.status == "finishing")
        #expect(try wire.toDomain().items.isEmpty)

        let closed = try Fixtures.api("listChanges.run_deletion")
        let closedWire = try ChangePageDTO.decode(try #require(closed.body), using: WireCoding.decoder())
        #expect(closedWire.deleted.map(\.kind) == [.run, .run, .run])
        let page = try closedWire.toDomain()
        #expect(page.deleted.isEmpty)
        #expect(page.items.count == 2)
        #expect(page.next == closedWire.next)
    }

    @Test func unknownFeedKindFailsThePage() throws {
        let json = """
            {"items":[{"kind":"comment","seq":1}],"deleted":[],"next":1,"has_more":false,"head":1,
             "epoch":"e","server_id":"s","server_time":"2026-06-01T12:00:00Z"}
            """
        #expect(throws: DecodingError.self) {
            try WireCoding.decoder().decode(ChangePageDTO.self, from: Data(json.utf8))
        }
    }

    @Test func problemsMapCodesAndLocations() throws {
        let problem = try Endpoints.decodeProblem(try #require(try Fixtures.api("createEntry.invalid_answers").body))
        #expect(problem.code == .invalidAnswers)
        #expect(problem.errors.first?.location == [.key("answers"), .key("glasses")])
        let deleted = try Endpoints.decodeProblem(try #require(try Fixtures.api("createEntry.entry_deleted").body))
        #expect(deleted.code == .entryDeleted)
        let notFound = try Endpoints.decodeProblem(try #require(try Fixtures.api("getTopic.not_found").body))
        #expect(notFound.code == .notFound)
        let indexed = try Endpoints.decodeProblem(
            Data(
                #"{"code":"invalid_request","detail":"x","errors":[{"loc":["questions",0,"max"],"message":"m"}]}"#.utf8)
        )
        #expect(indexed.errors.first?.location == [.key("questions"), .index(0), .key("max")])
    }

    @Test func problemCodesRoundTrip() {
        let raw = [
            "bad_request", "not_found", "conflict", "invalid_request", "invalid_answers", "incompatible_version",
            "topic_archived", "entry_deleted", "stale_revision", "server_mismatch", "epoch_mismatch", "internal_error",
            "topic_not_timed", "id_conflict", "before_start", "event_conflict", "run_open", "run_deleted",
            "run_too_long", "run_too_many_events",
        ]
        #expect(ProblemCode.known.map(\.rawValue) == raw)
        for code in raw { #expect(ProblemCode(rawValue: code).rawValue == code) }
        #expect(ProblemCode(rawValue: "teapot") == .unknown("teapot"))
    }

    @Test func statsAndSeries() throws {
        let stats = try decode(TopicStatsDTO.self, "getTopicStats")
        #expect(stats.questions.map(\.key) == ["glasses", "hours", "mood", "factors", "note"])
        guard case .numeric(let glasses) = stats.questions[0], case .choice(let mood) = stats.questions[2],
            case .text(let note) = stats.questions[4]
        else {
            Issue.record("unexpected stats kinds")
            return
        }
        #expect(glasses.type == .int && glasses.histogram.count == 6)
        #expect(mood.options.last?.option.archived == true)
        #expect(note.recent.count == note.count)
        let series = try decode(QuestionSeriesDTO.self, "getQuestionSeries.enum")
        #expect(series.bucket == .week && series.type == .enum)
        #expect(series.points.last?.optionCounts == ["ok": 1, "poor": 1])
    }

    @Test func versionsListAndCompatibility() throws {
        let versions = try decode([TopicVersionDTO].self, "listTopicVersions")
        #expect(versions.map(\.version) == [2, 1], "newest first")
        let report = try decode(CompatibilityReportDTO.self, "checkTopicVersion")
        #expect(report.ok && report.nextVersion == 3)
        #expect(report.changes.map(\.kind) == [.removed, .removed])
        #expect(report.issues.first?.level == .warning)
    }

    @Test func serverInfo() throws {
        #expect(try decode(HealthDTO.self, "health").isOK)
        let limits = try decode(LimitsDTO.self, "getLimits")
        #expect(limits.capturedAtMin == (try date("2000-01-01T00:00:00Z")))
        #expect(limits.capturedAtMaxFutureHours == 24)
        let types = try decode([QuestionTypeInfoDTO].self, "listQuestionTypes")
        #expect(types.map(\.type) == [.int, .double, .str, .enum])
        #expect(types.first?.jsonSchema["title"] == .string("IntQuestion"))
    }
}

@Suite(.timeLimit(.minutes(5))) struct RequestDTOTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try WireCoding.decoder().decode(T.self, from: WireCoding.encoder().encode(value))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(value)) as? [String: Any])
    }

    @Test func entryCreateEncodesTheWireShape() throws {
        let id = try #require(UUID(uuidString: "0F1E2D3C-4B5A-4968-8778-000000000001"))
        let body = EntryCreateDTO(
            id: id, answers: ["glasses": .int(6), "hours": .double(7.5), "factors": .strings(["a"])], source: "ios",
            capturedAt: try date("2026-03-01T08:05:00Z"), version: 2)
        let object = try json(body)
        #expect(object["id"] as? String == "0f1e2d3c-4b5a-4968-8778-000000000001")
        #expect(object["captured_at"] as? String == "2026-03-01T08:05:00+00:00")
        #expect(object["notes"] == nil && object["meta"] == nil)
        let answers = try #require(object["answers"] as? [String: Any])
        #expect(answers["glasses"] as? Int == 6)
        #expect(answers["factors"] as? [String] == ["a"])
        #expect(try roundTrip(body) == body)
    }

    @Test func entryUpdateNullRemovesAnAnswer() throws {
        let patch = EntryUpdateDTO(answers: ["note": nil, "glasses": .int(2)], expectedRevision: 3)
        let text = String(decoding: try WireCoding.encoder().encode(patch), as: UTF8.self)
        #expect(text == #"{"answers":{"glasses":2,"note":null},"expected_revision":3}"#)
        #expect(try roundTrip(patch) == patch)
    }

    @Test func topicUpdateScheduleIsThreeState() throws {
        let encoder = WireCoding.encoder()
        func text(_ update: TopicUpdateDTO) throws -> String {
            String(decoding: try encoder.encode(update), as: UTF8.self)
        }
        #expect(try text(TopicUpdateDTO(description: "x")) == #"{"description":"x"}"#)
        #expect(try text(TopicUpdateDTO(schedule: .null)) == #"{"schedule":null}"#)
        let interval = ScheduleInputDTO(.interval(.init(everyMinutes: 60, timezone: "UTC")))
        #expect(
            try text(TopicUpdateDTO(schedule: .value(interval)))
                == #"{"schedule":{"every_minutes":60,"kind":"interval","notify":true,"timezone":"UTC"}}"#)
        for update in [TopicUpdateDTO(), TopicUpdateDTO(schedule: .null), TopicUpdateDTO(schedule: .value(interval))] {
            #expect(try roundTrip(update) == update)
        }
    }

    @Test func questionsRoundTripThroughTheDomain() throws {
        let topic = try decode(TopicDetailDTO.self, "getTopic")
        let create = TopicCreateDTO(name: topic.name, questions: topic.questions, schedule: topic.schedule)
        let decoded = try roundTrip(create)
        #expect(decoded == create)
        #expect(try decoded.questions.toDomain() == topic.questions)
        #expect(try decoded.schedule?.toDomain() == topic.schedule)
    }

    /// A double answer of 7.0 is stored as `7` in a request-shaped map; the version's questions
    /// type it back.
    @Test func wholeDoubleAnswersSurviveThePayload() throws {
        let topic = try decode(TopicDetailDTO.self, "getTopic")
        let body = EntryCreateDTO(
            id: nil, answers: ["hours": .double(7.0), "glasses": .int(3), "mood": .string("ok")], source: "ios",
            capturedAt: Date(timeIntervalSince1970: 0), version: 2)
        let payload = OutboxPayload.entryCreate(
            topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name), body: body)
        guard case .entryCreate(_, let stored) = try OutboxPayload.decode(kind: .entryCreate, json: payload.encoded())
        else {
            Issue.record("expected entry.create")
            return
        }
        #expect(
            stored.domainAnswers(for: topic.questions) == [
                "hours": .double(7), "glasses": .int(3), "mood": .string("ok"),
            ])

        let patch = OutboxPayload.entryUpdate(
            entryId: "e", topicId: "t", patch: EntryUpdateDTO(answers: ["hours": .double(8), "note": nil]))
        guard
            case .entryUpdate(_, _, let storedPatch) = try OutboxPayload.decode(
                kind: .entryUpdate, json: patch.encoded())
        else {
            Issue.record("expected entry.update")
            return
        }
        let expectedPatch: [String: AnswerValue?] = ["hours": .double(8), "note": nil]
        #expect(storedPatch.domainAnswers(for: topic.questions) == expectedPatch)
        #expect(AnswerValue.double(4).normalized(for: topic.questions[0]) == .int(4))
        #expect(AnswerValue.double(4.5).normalized(for: topic.questions[0]) == .double(4.5))
    }

    @Test func outboxPayloadsRoundTrip() throws {
        let topic = TopicRef(id: UUID(), slug: "water", name: "Water")
        let payloads: [OutboxPayload] = [
            .entryCreate(
                topic: topic,
                body: EntryCreateDTO(
                    id: nil, answers: ["glasses": .int(1)], source: "ios.widget",
                    capturedAt: Date(timeIntervalSince1970: 0),
                    version: 1)),
            .entryUpdate(entryId: "e", topicId: topic.id, patch: EntryUpdateDTO(notes: "n", expectedRevision: 2)),
            .entryDelete(entryId: "e", topicId: topic.id),
            .topicArchive(topicId: topic.id),
            .topicUnarchive(topicId: topic.id),
        ]
        for payload in payloads {
            #expect(try OutboxPayload.decode(kind: payload.kind, json: payload.encoded()) == payload)
        }
        #expect(OutboxOrigin.allCases.map(\.source) == ["ios", "ios.widget", "ios.notification", "ios.siri"])
    }
}

@Suite(.timeLimit(.minutes(5))) struct APNsMappingTests {
    @Test func registerAndConfig() throws {
        let device = try decode(ApnsDeviceDTO.self, "registerApnsDevice")
        #expect(device.environment == .sandbox && device.bundleId == "com.bahumia.quickr")
        #expect(device.token.count == 64 && device.token == device.token.lowercased())
        #expect(try decode(PushConfigDTO.self, "getPushConfig").apnsEnabled)
        let body = String(
            decoding: try WireCoding.encoder().encode(ApnsDeviceRefDTO(token: device.token)), as: UTF8.self)
        #expect(body == #"{"token":"\#(device.token)"}"#)
    }
}
