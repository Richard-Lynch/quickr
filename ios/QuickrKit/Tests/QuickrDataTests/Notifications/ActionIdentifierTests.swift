import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// N3 (notifications.md §4.2, §7.1 step 1): action identifiers round-trip, malformed ones don't
/// parse, and one that doesn't match its reminder (a tampered value) is rejected.
@Suite(.timeLimit(.minutes(2))) struct ActionIdentifierTests {
    static let server = "0b9e0000-0000-4000-8000-0000000000aa"
    static let topic = "6f1c0000-0000-4000-8000-000000000001"

    /// Every action id of every vector parses back to itself.
    @Test func everyVectorActionRoundTrips() throws {
        let ids = NotificationVectorTests.vectors.cases.flatMap(\.expected.actions).map(\.identifier)
        #expect(ids.count > 40)
        for id in ids {
            let parsed = try #require(ActionIdentifier(id), "\(id)")
            #expect(parsed.description == id)
        }
    }

    @Test func malformedIdentifiersDontParse() {
        let base = "q1|\(Self.server)|\(Self.topic)|3|mood"
        for bad in [
            "q2|\(Self.server)|\(Self.topic)|3|mood|o|good",  // another scheme
            "q1|\(Self.server.uppercased())|\(Self.topic)|3|mood|o|good",  // not lowercase
            "q1|not-a-uuid|\(Self.topic)|3|mood|o|good",
            "q1|\(Self.server)|\(Self.topic)|03|mood|o|good",  // not canonical decimal
            "q1|\(Self.server)|\(Self.topic)|-3|mood|o|good",
            "q1|\(Self.server)|\(Self.topic)|3|Mood|o|good",  // key pattern
            "\(base)|x|good",  // unknown kind
            "\(base)|o|",  // an option needs a value
            "\(base)|i|7",  // input carries none
            "\(base)|m|x",  // nor does More…
            "\(base)|n|07.5", "\(base)|n|7.50", "\(base)|n|1e3", "\(base)|n|-0", "\(base)|n|",  // not fmt
            "\(base)|o",  // too few parts
            "q1|\(Self.server)|\(Self.topic)|3|mood\n|o|good",  // a newline after the key
            "\(base)|n|7.5\n", "\(base)|n|\n7.5",  // a newline around a number
        ] {
            #expect(ActionIdentifier(bad) == nil, "\(bad)")
        }
        // An option value may itself contain "|".
        #expect(ActionIdentifier("\(base)|o|a|b")?.value == "a|b")
    }

    static func info(_ quickLog: QuickLogDescriptor, version: Int = 3) -> QuickrNotificationInfo {
        QuickrNotificationInfo(
            kind: "due", serverId: server, topicId: topic, version: version, quickLog: quickLog)
    }

    @Test func anActionMustMatchTheReminderItCameWith() throws {
        let choice = Self.info(
            .choice(.init(key: "mood", label: "Mood", options: [.init(value: "good", label: "Good")], totalOptions: 5)))
        let good = ActionIdentifier(
            serverId: Self.server, topicId: Self.topic, version: 3, key: "mood", kind: .option, value: "good")
        #expect(good.matches(choice))
        var tampered = good
        tampered.value = "bad"
        #expect(!tampered.matches(choice), "an option the reminder doesn't offer")
        for change in [
            { (a: inout ActionIdentifier) in a.version = 4 },
            { (a: inout ActionIdentifier) in a.key = "other" },
            { (a: inout ActionIdentifier) in a.topicId = UUID().wireString },
            { (a: inout ActionIdentifier) in a.serverId = UUID().wireString },
        ] {
            var other = good
            change(&other)
            #expect(!other.matches(choice))
        }
        let more = ActionIdentifier(serverId: Self.server, topicId: Self.topic, version: 3, key: "mood", kind: .more)
        #expect(more.matches(choice))

        let number = Self.info(.number(.init(type: "double", key: "mood", label: "Hours", lastValue: .double(7.5))))
        let last = ActionIdentifier(
            serverId: Self.server, topicId: Self.topic, version: 3, key: "mood", kind: .number, value: "7.5")
        #expect(last.matches(number))
        var otherValue = last
        otherValue.value = "8"
        #expect(!otherValue.matches(number), "a value other than fmt(last_value)")
        #expect(!last.matches(choice) && !good.matches(number), "a kind the descriptor doesn't have")
        let input = ActionIdentifier(serverId: Self.server, topicId: Self.topic, version: 3, key: "mood", kind: .input)
        #expect(input.matches(number))
    }
}
