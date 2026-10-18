import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// "server error locations" in frontend/src/lib/constraints.test.ts, frontend/src/api/errors.ts,
/// and the entry form's fix mode.
@Suite(.timeLimit(.minutes(2))) struct ProblemMappingTests {
    typealias P = FieldIssue.PathComponent

    @Test func keepsEntryLocsRelativeToTheBody() {
        #expect(ProblemMapping.path([.key("answers"), .key("factors"), .index(2)]) == "answers.factors.2")
        #expect(ProblemMapping.path([.key("body"), .key("captured_at")]) == "captured_at")
    }

    @Test func dropsUnionTagsShouldTheyAppear() {
        let question: [P] = [
            .key("body"), .key("questions"), .index(0), .key("enum"), .key("options"), .index(1), .key("value"),
        ]
        #expect(ProblemMapping.path(question) == "questions.0.options.1.value")
        let schedule: [P] = [.key("body"), .key("schedule"), .key("daily"), .key("times"), .index(0)]
        #expect(ProblemMapping.path(schedule) == "schedule.times.0")
        // Only as tags: a question key that happens to be "int" survives.
        #expect(ProblemMapping.path([.key("answers"), .key("int")]) == "answers.int")
        #expect(ProblemMapping.path([.key("answers"), .key("body")]) == "answers.body")
    }

    @Test func cleansPydanticMessages() {
        #expect(
            ProblemMapping.cleanMessage("Value error, min must be <= max [type=value_error]") == "Min must be <= max")
        #expect(ProblemMapping.cleanMessage("must be <= 30") == "Must be <= 30")
        #expect(ProblemMapping.cleanMessage("  ") == "")
    }

    @Test func banners() {
        let one = Problem(
            code: .invalidRequest, detail: "request validation failed",
            errors: [.init(location: [.key("body"), .key("captured_at")], message: "Input should have timezone info")])
        #expect(ProblemMapping.banner(for: one) == "captured_at: Input should have timezone info")
        let rootless = Problem(
            code: .invalidRequest, detail: "x", errors: [.init(location: [.key("body")], message: "bad")])
        #expect(ProblemMapping.banner(for: rootless) == "Bad")
        #expect(ProblemMapping.banner(for: Problem(code: .invalidRequest, detail: "x")) == "Some fields need attention")
        #expect(
            ProblemMapping.banner(for: Problem(code: .invalidAnswers, detail: "one or more answers are invalid"))
                == "One or more answers are invalid")
        #expect(ProblemMapping.banner(for: Problem(code: .topicArchived, detail: "")) == "This topic is archived")
        #expect(ProblemMapping.banner(for: Problem(code: .unknown("teapot"), detail: " ")) == "Request failed")
    }

    @Test func landsEntryErrorsOnTheirFields() {
        let problem = Problem(
            code: .invalidAnswers, detail: "one or more answers are invalid",
            errors: [
                .init(location: [.key("answers"), .key("glasses")], message: "must be <= 30"),
                .init(location: [.key("answers"), .key("factors"), .index(1)], message: "'zzz' is not an option"),
                .init(location: [.key("answers"), .key("factors"), .index(2)], message: "option 'x' is archived"),
                .init(location: [.key("answers"), .key("gone")], message: "unknown question"),
                .init(location: [.key("body"), .key("captured_at")], message: "Input should have timezone info"),
                .init(location: [.key("notes")], message: "too long"),
                .init(location: [.key("source")], message: "too long"),
                .init(location: [.key("meta"), .key("k")], message: "bad"),
            ])
        let mapped = ProblemMapping.entryForm(problem, questionKeys: ["glasses", "factors"])
        #expect(mapped.banner == "One or more answers are invalid")
        #expect(
            mapped.fields == [
                .answer("glasses"): "Must be <= 30",
                // The last issue for a field wins.
                .answer("factors"): "Option 'x' is archived",
                .capturedAt: "Input should have timezone info",
                .notes: "Too long",
                .source: "Too long",
            ])
        #expect(
            mapped.unplaced == [
                .init(location: [.key("answers"), .key("gone")], message: "Unknown question"),
                .init(location: [.key("meta"), .key("k")], message: "Bad"),
            ])
    }

    @Test func recordedInvalidAnswersFixture() throws {
        let problem = try Self.problem("createEntry.invalid_answers")
        let mapped = ProblemMapping.entryForm(problem, questionKeys: ["glasses", "hours", "mood", "factors"])
        #expect(
            mapped.fields == [
                .answer("glasses"): "Must be <= 30", .answer("hours"): "Required",
                .answer("mood"): "Option is archived",
                .answer("factors"): "Select at most 2 options",
            ])
        #expect(mapped.unplaced.isEmpty)
    }

    @Test func recordedInvalidRequestFixture() throws {
        let problem = try Self.problem("createEntry.invalid_request")
        let mapped = ProblemMapping.entryForm(problem, questionKeys: ["glasses"])
        #expect(mapped.banner == "captured_at: Input should have timezone info")
        #expect(mapped.fields == [.capturedAt: "Input should have timezone info"])
    }

    /// The fixture's Problem body, decoded without QuickrData.
    static func problem(_ name: String) throws -> Problem {
        let body = try #require(try Fixtures.api(name).body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let errors = (json["errors"] as? [[String: Any]] ?? []).map { issue in
            FieldIssue(
                location: (issue["loc"] as? [Any] ?? []).map { ($0 as? Int).map(P.index) ?? .key("\($0)") },
                message: issue["message"] as? String ?? "")
        }
        return Problem(
            code: ProblemCode(rawValue: json["code"] as? String ?? ""), detail: json["detail"] as? String ?? "",
            errors: errors)
    }
}

/// `captured_at`, `source` and `notes` (entryMeta.ts; constraints.test.ts).
@Suite(.timeLimit(.minutes(2))) struct EntryMetaValidationTests {
    static let limits = Limits(
        keyPattern: "", slugPattern: "", timePattern: "", maxQuestions: 50, maxEnumOptions: 50, maxStrLength: 5000,
        maxLabelLength: 200, maxHelpTextLength: 500, maxUnitLength: 20, maxDecimals: 10, maxTopicNameLength: 100,
        maxDescriptionLength: 1000, maxChangeNoteLength: 500, maxSourceLength: 5, maxNotesLength: 3, maxMetaEntries: 20,
        maxMetaKeyLength: 64, maxMetaValueLength: 500, capturedAtMin: Self.date("2000-01-01T00:00:00Z"),
        capturedAtMaxFutureHours: 24, scheduleMaxTimes: 12, intervalMinMinutes: 15, intervalMaxMinutes: 129_600)

    static func date(_ iso: String) -> Date {
        (try? Date(iso, strategy: .iso8601)) ?? .distantPast
    }

    @Test func capturedAtNotBefore2000NotMoreThan24HoursAhead() {
        let now = Self.date("2026-10-15T12:00:00Z")
        let issue = { EntryMetaValidation.capturedAtIssue(Self.date($0), limits: Self.limits, now: now) }
        #expect(issue("1999-12-31T23:59:00Z") == "Can’t be before 2000")
        #expect(issue("2026-10-16T12:01:00Z") == "Can’t be more than 24 hours in the future")
        #expect(issue("2026-10-16T11:59:00Z") == nil)
        #expect(issue("2000-01-01T00:00:00Z") == nil)
    }

    @Test func sourceAndNotes() {
        #expect(
            EntryMetaValidation.source("  ", limits: Self.limits) == .failure("Where did this come from? (e.g. phone)"))
        #expect(EntryMetaValidation.source(" phone ", limits: Self.limits) == .success("phone"))
        #expect(EntryMetaValidation.source("phones", limits: Self.limits) == .failure("At most 5 characters"))
        #expect(EntryMetaValidation.notes(" abc ", limits: Self.limits) == .success("abc"))
        #expect(EntryMetaValidation.notes("abcd", limits: Self.limits) == .failure("At most 3 characters"))
        #expect(EntryMetaValidation.notes("", limits: Self.limits) == .success(""))
    }
}
