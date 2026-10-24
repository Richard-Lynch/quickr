import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// N3 (notifications.md §4.2, §7.1 step 1): action identifiers round-trip, malformed ones don't
/// parse, and one that doesn't match its reminder (a tampered value) is rejected.
@Suite(.timeLimit(.minutes(5))) struct ActionIdentifierTests {
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

    /// SINGLE: a topic with no questions has one action, "Log it": kind `s`, with an empty key and
    /// value. Only `s` takes an empty key, and `s` takes nothing else.
    @Test func aSingleTopicsLogItRoundTripsAndMatchesOnlyASingleReminder() throws {
        let id = "q1|\(Self.server)|\(Self.topic)|3||s|"
        let parsed = try #require(ActionIdentifier(id))
        #expect(parsed.kind == .single && parsed.key.isEmpty && parsed.value.isEmpty)
        #expect(parsed.description == id)
        for bad in [
            "q1|\(Self.server)|\(Self.topic)|3|mood|s|",  // `s` has no key
            "q1|\(Self.server)|\(Self.topic)|3||s|x",  // nor a value
            "q1|\(Self.server)|\(Self.topic)|3||o|good",  // every other kind needs a key
            "q1|\(Self.server)|\(Self.topic)|3||i|",
        ] {
            #expect(ActionIdentifier(bad) == nil, "\(bad)")
        }
        #expect(parsed.matches(Self.info(.single)))
        #expect(!parsed.matches(Self.info(.single, version: 4)))
        let choice = Self.info(
            .choice(.init(key: "mood", label: "Mood", options: [.init(value: "good", label: "Good")], totalOptions: 1)))
        #expect(!parsed.matches(choice))
    }

    /// SINGLE: the category of a topic with no questions, its `{"type": "single"}` descriptor as
    /// JSON (both ways), and a reminder carrying it is well formed.
    @Test func aSingleTopicsCategoryAndDescriptor() throws {
        let category = try #require(
            NotificationCategory(serverId: Self.server, topicId: Self.topic, version: 3, questions: []))
        #expect(category.descriptor == .single)
        #expect(category.actions.map(\.kind) == ["log"])
        #expect(category.actions.map(\.title) == ["Log it"])
        #expect(category.actions.map(\.identifier) == ["q1|\(Self.server)|\(Self.topic)|3||s|"])
        #expect(category.id.hasPrefix("quickr.t.\(Self.topic)."))
        let json = try JSONEncoder().encode(QuickLogDescriptor.single)
        #expect(String(decoding: json, as: UTF8.self) == #"{"type":"single"}"#)
        #expect(try JSONDecoder().decode(QuickLogDescriptor.self, from: Data(#"{"type":"single"}"#.utf8)) == .single)
        #expect(NotificationPreparation.isWellFormed(Self.info(.single)))
    }

    /// T-PUSH: a timed topic's `{"type": "timed"}` descriptor reads and writes as JSON, renders one
    /// "Start" (`…||t|`, kind `start`) whatever the questions, and its identifier parses. The handler
    /// doesn't act on it yet (I-NOTIF, timers.md §10.2), so it doesn't match a reminder.
    @Test func aTimedTopicsCategoryAndDescriptor() throws {
        let category = try #require(
            NotificationCategory(serverId: Self.server, topicId: Self.topic, version: 3, questions: [], timed: true))
        #expect(category.descriptor == .timed)
        #expect(category.actions.map(\.kind) == ["start"])
        #expect(category.actions.map(\.title) == ["Start"])
        #expect(category.actions.map(\.identifier) == ["q1|\(Self.server)|\(Self.topic)|3||t|"])
        #expect(category.actions.compactMap(\.spec).isEmpty, "Start is registered by I-NOTIF")
        let json = try JSONEncoder().encode(QuickLogDescriptor.timed)
        #expect(String(decoding: json, as: UTF8.self) == #"{"type":"timed"}"#)
        #expect(try JSONDecoder().decode(QuickLogDescriptor.self, from: Data(#"{"type":"timed"}"#.utf8)) == .timed)
        let parsed = try #require(ActionIdentifier("q1|\(Self.server)|\(Self.topic)|3||t|"))
        #expect(parsed.kind == .start && parsed.key.isEmpty && parsed.value.isEmpty)
        #expect(ActionIdentifier("q1|\(Self.server)|\(Self.topic)|3|mood|t|") == nil)
        #expect(ActionIdentifier("q1|\(Self.server)|\(Self.topic)|3||t|x") == nil)
        #expect(!parsed.matches(Self.info(.timed)))
        #expect(NotificationPreparation.isWellFormed(Self.info(.timed)))
    }

    /// A quick_log type this build doesn't know (a newer server's) is a plain reminder: the payload
    /// still reads (slot, url, a well-formed reminder), with no descriptor, so no actions. Before,
    /// the whole `quickr` object failed to decode. A known type that's malformed still fails.
    @Test func anUnknownQuickLogTypeIsAPlainReminder() throws {
        func payload(_ quickLog: [String: Any]) -> [AnyHashable: Any] {
            [
                "quickr": [
                    "v": 1, "kind": "due", "server_id": Self.server, "topic_id": Self.topic, "version": 3,
                    "due_since": "2026-03-04T11:00:00Z", "url": "/t/water/record", "quick_log": quickLog,
                ] as [String: Any]
            ]
        }
        let info = try #require(QuickrNotificationInfo(userInfo: payload(["type": "stars", "max": 5])))
        #expect(info.quickLog == nil && info.slot != nil && info.url == "/t/water/record")
        #expect(NotificationPreparation.isWellFormed(info))
        #expect(SystemNotificationCenter.quickr(payload(["type": "stars"]))?.quickLog == nil)
        #expect(QuickrNotificationInfo(userInfo: payload(["type": "single"]))?.quickLog == .single)
        #expect(QuickrNotificationInfo(userInfo: payload(["type": "enum"])) == nil, "a known type, malformed")
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
