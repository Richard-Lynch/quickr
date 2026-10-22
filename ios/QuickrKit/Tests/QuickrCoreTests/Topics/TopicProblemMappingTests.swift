import QuickrCore
import Testing

/// The PWA's `SettingsPage` error handling (`MetaForm`, `ScheduleForm`) over `mapApiError` and
/// `applyFieldErrors`, case by case.
@Suite struct TopicProblemMappingTests {
    static func issue(_ path: [FieldIssue.PathComponent], _ message: String) -> FieldIssue {
        FieldIssue(location: [.key("body")] + path, message: message)
    }

    // MARK: Details

    @Test func detailsIssuesThatAllLandShowNoBanner() {
        let problem = Problem(
            code: .invalidRequest, detail: "Request validation failed",
            errors: [
                Self.issue([.key("name")], "String should have at least 1 character"),
                Self.issue([.key("slug")], "Value error, bad slug"),
            ])
        let errors = TopicProblemMapping.details(problem)
        #expect(errors.banner == nil)
        #expect(errors.fields == [.name: "String should have at least 1 character", .slug: "Bad slug"])
    }

    @Test func detailsUnplacedIssuesJoinTheBanner() {
        let problem = Problem(
            code: .invalidRequest, detail: "Request validation failed",
            errors: [Self.issue([.key("name")], "too long"), Self.issue([.key("schedule")], "nope")])
        let errors = TopicProblemMapping.details(problem)
        #expect(errors.banner == "Some fields need attention — Nope")
        #expect(errors.fields == [.name: "Too long"])
    }

    @Test func aSlugConflictWithoutALocationLandsOnTheSlug() {
        let errors = TopicProblemMapping.details(Problem(code: .conflict, detail: "slug 'mood' is already taken"))
        #expect(errors.banner == nil)
        #expect(errors.fields == [.slug: "Slug 'mood' is already taken"])
    }

    @Test func anotherConflictIsABanner() {
        let errors = TopicProblemMapping.details(Problem(code: .conflict, detail: "the topic changed"))
        #expect(errors.banner == "The topic changed")
        #expect(errors.fields.isEmpty)
    }

    @Test func aLaterIssueReplacesAnEarlierOneOnTheSameField() {
        let problem = Problem(
            code: .invalidRequest, detail: "x",
            errors: [Self.issue([.key("name")], "first"), Self.issue([.key("name")], "second")])
        #expect(TopicProblemMapping.details(problem).fields == [.name: "Second"])
    }

    // MARK: Schedule

    @Test func scheduleIssuesLandOnTheirFieldsWithoutABanner() {
        let problem = Problem(
            code: .invalidRequest, detail: "Request validation failed",
            errors: [
                Self.issue([.key("schedule"), .key("times"), .index(1)], "Value error, duplicate time '08:00'"),
                Self.issue([.key("schedule"), .key("every_minutes")], "Input should be greater than or equal to 15"),
                Self.issue([.key("schedule"), .key("timezone")], "unknown time zone"),
            ])
        let errors = TopicProblemMapping.schedule(problem)
        #expect(errors.banner == nil)
        #expect(
            errors.fields == [
                .time(1): "Duplicate time '08:00'", .every: "Input should be greater than or equal to 15",
                .timezone: "Unknown time zone",
            ])
    }

    @Test func scheduleTaggedUnionPathsDropTheTag() {
        let problem = Problem(
            code: .invalidRequest, detail: "x",
            errors: [Self.issue([.key("schedule"), .key("daily"), .key("days"), .index(0)], "bad day")])
        #expect(TopicProblemMapping.schedule(problem).fields == [.days: "Bad day"])
    }

    @Test func aScheduleProblemWithoutIssuesIsABanner() {
        let errors = TopicProblemMapping.schedule(Problem(code: .notFound, detail: "topic not found"))
        #expect(errors.banner == "Topic not found")
        #expect(errors.fields.isEmpty)
    }

    @Test func aNonScheduleIssueOnTheScheduleFormIsABanner() {
        let problem = Problem(code: .invalidRequest, detail: "x", errors: [Self.issue([.key("name")], "odd")])
        let errors = TopicProblemMapping.schedule(problem)
        #expect(errors.banner == "name: Odd — Odd")
        #expect(errors.fields.isEmpty)
    }
}
