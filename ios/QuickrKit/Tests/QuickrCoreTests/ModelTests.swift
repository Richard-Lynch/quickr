import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(2))) struct ModelTests {
    @Test func timeOfDayParsesTheServerPattern() {
        #expect(TimeOfDay("08:00") == TimeOfDay(hour: 8, minute: 0))
        #expect(TimeOfDay("23:59")?.description == "23:59")
        #expect(TimeOfDay(hour: 7, minute: 5).description == "07:05")
        for bad in ["24:00", "8:00", "08:60", "0800", "08:0a", "", "08:00:00"] {
            #expect(TimeOfDay(bad) == nil, "\(bad)")
        }
        #expect(TimeOfDay(hour: 8, minute: 0) < TimeOfDay(hour: 21, minute: 30))
    }

    @Test func questionTypeFollowsKind() {
        let choice = Question(
            key: "mood", label: "Mood", kind: .choice(.init(options: [.init(value: "a", label: "A")])))
        #expect(choice.type == .enum && choice.required)
        #expect(Question(key: "n", label: "N", kind: .string(.init())).type == .str)
        #expect(Question.StringRules().maxLength == 500)
    }

    @Test func sharedVectorsLoad() throws {
        let due = try #require(try JSONSerialization.jsonObject(with: Fixtures.dueVectors()) as? [String: Any])
        #expect(due["due"] is [Any] && due["slots"] is [Any] && due["messages"] is [Any])
        let quicklog = try #require(
            try JSONSerialization.jsonObject(with: Fixtures.quicklogVectors()) as? [String: Any])
        #expect(quicklog["eligibility"] is [Any] && quicklog["initial"] is [Any])
    }
}
