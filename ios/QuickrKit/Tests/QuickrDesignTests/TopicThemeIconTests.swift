import Foundation
import QuickrCore
import Testing

/// `checkIcon` and `checkTags` (appearance.md §2, §1.3, §5) over `icons[]` and `tags[]` of
/// `shared/fixtures/appearance-vectors.json`, which the server's validator generates (§3.3 puts
/// them in `TopicThemeTests`). The messages are the server's; the client words its own, so only
/// the outcome, the stored form and the location are compared.
extension TopicThemeTests {
    struct IconCase: Decodable, CustomTestStringConvertible {
        struct Expected: Decodable {
            let ok: Bool
            let value: String?
        }

        let name: String
        let value: String
        let expected: Expected
        var testDescription: String { name }
    }

    struct TagsCase: Decodable, CustomTestStringConvertible {
        struct Expected: Decodable {
            let ok: Bool
            let value: [String]?
            /// `tags.2` (one tag) or `tags` (too many).
            let loc: String?
        }

        let name: String
        let input: [String]
        let expected: Expected
        var testDescription: String { name }

        /// The offending tag `loc` names; nil for the whole list.
        var index: Int? {
            guard let loc = expected.loc, let dot = loc.firstIndex(of: ".") else { return nil }
            return Int(loc[loc.index(after: dot)...])
        }
    }

    struct ValidationVectors: Decodable {
        let icons: [IconCase]
        let tags: [TagsCase]
    }

    static let validation: ValidationVectors = {
        let url = TokenDriftTests.repo.appending(path: "shared/fixtures/appearance-vectors.json")
        do {
            return try JSONDecoder().decode(ValidationVectors.self, from: Data(contentsOf: url))
        } catch {
            fatalError("appearance-vectors.json: \(error)")
        }
    }()

    @Test func theVectorsHaveTheCasesOfTheSpec() {
        // §3.2: at least 17 icon and 8 tag cases.
        #expect(Self.validation.icons.count >= 17)
        #expect(Self.validation.tags.count >= 8)
    }

    @Test(arguments: validation.icons) func checkIconMatchesTheVectors(_ vector: IconCase) {
        switch TopicAppearance.checkIcon(vector.value) {
        case .success(let stored):
            #expect(vector.expected.ok, "accepted \(vector.name)")
            // Code point by code point: the stored form is what the server keeps.
            #expect(Array(stored.unicodeScalars) == Array((vector.expected.value ?? "").unicodeScalars))
        case .failure:
            #expect(!vector.expected.ok, "refused \(vector.name)")
        }
    }

    @Test(arguments: validation.tags) func checkTagsMatchesTheVectors(_ vector: TagsCase) {
        switch TopicAppearance.checkTags(vector.input) {
        case .success(let value):
            #expect(vector.expected.ok, "accepted \(vector.name)")
            #expect(
                value.map { Array($0.unicodeScalars) } == (vector.expected.value ?? []).map { Array($0.unicodeScalars) }
            )
        case .failure(let issue):
            #expect(!vector.expected.ok, "refused \(vector.name)")
            #expect(issue.index == vector.index, "\(vector.name) at \(vector.expected.loc ?? "?")")
        }
    }

    /// The client's own words, and the limits coming from `Limits` (`GET /limits`).
    @Test func checkIconMessagesAndLimits() throws {
        #expect(TopicAppearance.checkIcon("") == .failure(AppearanceIssue(message: AppearanceMessage.iconEmpty)))
        #expect(TopicAppearance.checkIcon("ab") == .failure(AppearanceIssue(message: AppearanceMessage.iconNotOne)))
        #expect(TopicAppearance.checkIcon("a") == .failure(AppearanceIssue(message: AppearanceMessage.iconText)))
        var tight = Limits.serverDefaults
        tight.maxIconLength = 1
        #expect(throws: AppearanceIssue.self) { try TopicAppearance.checkIcon("☺", limits: tight).get() }
        #expect(try TopicAppearance.checkIcon("🚬", limits: tight).get() == "🚬")
    }

    @Test func checkTagsMessagesAndLimits() {
        #expect(
            TopicAppearance.checkTags(["Gym", "gym"])
                == .failure(AppearanceIssue(index: 1, message: AppearanceMessage.tagDuplicate("gym"))))
        #expect(
            TopicAppearance.checkTags((1...11).map { "t\($0)" })
                == .failure(AppearanceIssue(message: AppearanceMessage.tooManyTags(10))))
        var tight = Limits.serverDefaults
        tight.maxTags = 1
        tight.maxTagLength = 3
        #expect(
            TopicAppearance.checkTags(["a", "b"], limits: tight) == .failure(AppearanceIssue(message: "At most 1 tags"))
        )
        #expect(
            TopicAppearance.checkTags(["gyms"], limits: tight)
                == .failure(AppearanceIssue(index: 0, message: AppearanceMessage.tagTooLong(3))))
    }
}
