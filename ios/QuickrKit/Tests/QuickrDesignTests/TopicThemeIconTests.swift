import Foundation
import QuickrCore
import Testing

/// `checkIcon` and `checkTags` (appearance.md §2, §1.3, §5; §3.3 puts them in `TopicThemeTests`).
extension TopicThemeTests {
    enum Expected: Equatable {
        case ok(String)
        case refused
    }

    // T2-M3: repoint at appearance-vectors.json (`icons[]`) once M3-DB generates it. Copied from
    // appearance.md §3.2, plus the two lone-component cases the server table refuses.
    static let icons: [(name: String, value: String, expected: Expected)] = [
        ("plain", "🚬", .ok("🚬")),
        ("vs16_added", "☺", .ok("☺\u{FE0F}")),
        ("vs16_present", "☺\u{FE0F}", .ok("☺\u{FE0F}")),
        ("copyright_vs16", "©\u{FE0F}", .ok("©\u{FE0F}")),
        ("zwj_family", "👨‍👩‍👧", .ok("👨‍👩‍👧")),
        ("skin_tone", "👍🏽", .ok("👍🏽")),
        ("flag", "🇮🇪", .ok("🇮🇪")),
        ("keycap", "1\u{FE0F}\u{20E3}", .ok("1\u{FE0F}\u{20E3}")),
        ("letter", "a", .refused),
        ("digit", "5", .refused),
        ("digit_vs16", "5\u{FE0F}", .refused),
        ("hash_vs16_no_keycap", "#\u{FE0F}", .refused),
        ("two_emoji", "🚬🚬", .refused),
        ("emoji_plus_letter", "🚬a", .refused),
        ("empty", "", .refused),
        ("too_long", tagSequence(tags: 16), .refused),
        ("text_symbol_no_vs16_unfixable", "→", .refused),
        ("lone_regional_indicator", "🇮", .refused),
        ("lone_skin_tone", "🏽", .refused),
    ]

    /// A black flag and `tags` tag characters ending in CANCEL TAG: one cluster of `tags + 1` code
    /// points.
    static func tagSequence(tags: Int) -> String {
        var value = "\u{1F3F4}"
        for _ in 0..<(tags - 1) { value.unicodeScalars.append("\u{E0067}") }
        value.unicodeScalars.append("\u{E007F}")
        return value
    }

    @Test(arguments: icons.indices) func checkIconMatchesTheVectors(_ i: Int) {
        let (name, value, expected) = Self.icons[i]
        let got: Expected =
            switch TopicAppearance.checkIcon(value) {
            case .success(let stored): .ok(stored)
            case .failure: .refused
            }
        #expect(got == expected, "\(name)")
    }

    /// The documented edges: 16 code points is the most; NFC first; a bare `©` gains its VS16 like
    /// `☺`; ASCII never starts an emoji without the full keycap sequence.
    @Test func checkIconEdges() throws {
        #expect(throws: Never.self) { try TopicAppearance.checkIcon(Self.tagSequence(tags: 15)).get() }
        #expect(try TopicAppearance.checkIcon("©").get() == "©\u{FE0F}")
        #expect(try TopicAppearance.checkIcon("#\u{FE0F}\u{20E3}").get() == "#\u{FE0F}\u{20E3}")
        #expect(throws: AppearanceIssue.self) { try TopicAppearance.checkIcon("#\u{20E3}").get() }
        let tight = AppearanceLimits(maxTags: 10, maxTagLength: 24, maxIconLength: 1)
        #expect(throws: AppearanceIssue.self) { try TopicAppearance.checkIcon("☺\u{FE0F}", limits: tight).get() }
        #expect(TopicAppearance.checkIcon("") == .failure(AppearanceIssue(message: AppearanceMessage.iconEmpty)))
        #expect(TopicAppearance.checkIcon("ab") == .failure(AppearanceIssue(message: AppearanceMessage.iconNotOne)))
        #expect(TopicAppearance.checkIcon("a") == .failure(AppearanceIssue(message: AppearanceMessage.iconText)))
    }

    enum TagsExpected: Equatable {
        case ok([String])
        case refused(index: Int?)
    }

    // T2-M3: repoint at appearance-vectors.json (`tags[]`) once M3-DB generates it. The cases of
    // appearance.md §3.2.
    static let tags: [(name: String, input: [String], expected: TagsExpected)] = [
        ("trim", ["  gym  "], .ok(["gym"])),
        ("collapse", ["morning \t  run"], .ok(["morning run"])),
        ("casefold_duplicate", ["Gym", "run", "GYM"], .refused(index: 2)),
        ("casefold_full", ["Straße", "STRASSE"], .refused(index: 1)),
        ("eleventh_tag", (1...11).map { "t\($0)" }, .refused(index: nil)),
        ("ten_tags", (1...10).map { "t\($0)" }, .ok((1...10).map { "t\($0)" })),
        ("too_long", ["gym", String(repeating: "a", count: 25)], .refused(index: 1)),
        ("longest", [String(repeating: "a", count: 24)], .ok([String(repeating: "a", count: 24)])),
        ("empty_after_trim", ["gym", " \n "], .refused(index: 1)),
        ("order_kept", ["b", "a", "c"], .ok(["b", "a", "c"])),
        ("control_character", ["gym\u{7}"], .refused(index: 0)),
        // Python `str.isspace()` (U+001C–U+001F are spaces, not control characters): not in §3.2.
        ("python_isspace", ["\u{1C}gym\u{1F}run"], .ok(["gym run"])),
        ("none", [], .ok([])),
    ]

    @Test(arguments: tags.indices) func checkTagsMatchesTheVectors(_ i: Int) {
        let (name, input, expected) = Self.tags[i]
        let got: TagsExpected =
            switch TopicAppearance.checkTags(input) {
            case .success(let value): .ok(value)
            case .failure(let issue): .refused(index: issue.index)
            }
        #expect(got == expected, "\(name)")
    }

    @Test func checkTagsMessages() {
        #expect(
            TopicAppearance.checkTags(["Gym", "gym"])
                == .failure(AppearanceIssue(index: 1, message: AppearanceMessage.tagDuplicate("gym"))))
        #expect(
            TopicAppearance.checkTags((1...11).map { "t\($0)" })
                == .failure(AppearanceIssue(message: AppearanceMessage.tooManyTags(10))))
    }
}
