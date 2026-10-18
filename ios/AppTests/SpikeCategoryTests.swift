#if DEBUG
import Foundation
import QuickrData
import Testing

@testable import QuickR

/// SPIKE: the spike's action rendering against the B7 cross-language vectors
/// (shared/fixtures/notification-vectors.json), so its literals can't drift from the server's.
/// The category id itself comes from the payload (the spike doesn't hash; CAT owns §4.3).
@Suite struct SpikeCategoryTests {
    /// Literals the spike was checked against: the `enum-4` and `enum-non-ascii` cases'
    /// category ids, as the server computes them.
    static let literals = [
        "enum-4": "quickr.t.6f1c0000-0000-4000-8000-000000000001.3b73ba68e16058e2",
        "enum-non-ascii": "quickr.t.6f1c0000-0000-4000-8000-000000000001.67e57bf6db2906b8",
    ]

    static func vectors() throws -> [[String: Any]] {
        // <repo>/ios/AppTests/SpikeCategoryTests.swift → <repo>/shared/fixtures (the simulator
        // reads the host's file system).
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appending(path: "shared/fixtures/notification-vectors.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["cases"] as? [[String: Any]])
    }

    @Test(arguments: ["enum-4", "enum-non-ascii"])
    func enumActionsMatchTheVectors(name: String) throws {
        let vector = try #require(try Self.vectors().first { $0["name"] as? String == name })
        let expected = try #require(vector["expected"] as? [String: Any])
        #expect(expected["category_id"] as? String == Self.literals[name])

        // The payload the server would send: aps.category plus the quickr object.
        let quickLog = try #require(expected["quick_log"])
        let quickr: [String: Any] = [
            "v": 1, "kind": "due", "server_id": try #require(vector["server_id"]),
            "topic_id": try #require(vector["topic_id"]), "version": try #require(vector["version"]),
            "quick_log": quickLog,
        ]
        let payload: [AnyHashable: Any] = ["aps": ["category": Self.literals[name] ?? ""], "quickr": quickr]
        let row = try #require(SpikeCategories.row(userInfo: payload))
        #expect(row.id == Self.literals[name])

        let actions = try #require(expected["actions"] as? [[String: String]])
        #expect(row.actions.map(\.id) == actions.map { $0["identifier"] ?? "" })
        #expect(row.actions.map(\.title) == actions.map { $0["title"] ?? "" })
        #expect(actions.allSatisfy { $0["kind"] == "log" })
    }

    @Test func actionsAreValidatedAgainstTheirNotification() throws {
        let vector = try #require(try Self.vectors().first { $0["name"] as? String == "enum-4" })
        let expected = try #require(vector["expected"] as? [String: Any])
        let quickr: [String: Any] = [
            "v": 1, "kind": "due", "server_id": try #require(vector["server_id"]),
            "topic_id": try #require(vector["topic_id"]), "version": try #require(vector["version"]),
            "quick_log": try #require(expected["quick_log"]),
        ]
        let actions = try #require(expected["actions"] as? [[String: String]])
        let first = try #require(actions.first?["identifier"])
        let (_, answer) = try SpikeHandler.validate(action: first, userInfo: ["quickr": quickr])
        #expect(answer.key == "mood")
        // Another topic's, another version's or an unknown option's identifier is refused.
        for forged in [
            first.replacingOccurrences(
                of: "6f1c0000-0000-4000-8000-000000000001", with: "6f1c0000-0000-4000-8000-000000000002"),
            first.replacingOccurrences(of: "|1|mood|", with: "|2|mood|"),
            first.components(separatedBy: "|").dropLast().joined(separator: "|") + "|nope",
        ] {
            #expect(throws: SpikeError.self) { try SpikeHandler.validate(action: forged, userInfo: ["quickr": quickr]) }
        }
    }

    /// Both versions must parse: a payload without a version (missing or null) never matches an
    /// action, and a malformed action version never matches a payload's.
    @Test func versionsMustBothParse() throws {
        let vector = try #require(try Self.vectors().first { $0["name"] as? String == "enum-4" })
        let expected = try #require(vector["expected"] as? [String: Any])
        let action = try #require((expected["actions"] as? [[String: String]])?.first?["identifier"])
        var quickr: [String: Any] = [
            "v": 1, "kind": "due", "server_id": try #require(vector["server_id"]),
            "topic_id": try #require(vector["topic_id"]), "quick_log": try #require(expected["quick_log"]),
        ]
        let garbage = action.replacingOccurrences(of: "|1|mood|", with: "|garbage|mood|")
        for version in [nil, NSNull()] as [Any?] {  // missing, then null
            quickr["version"] = version
            for candidate in [action, garbage] {
                #expect(throws: SpikeError.self) {
                    try SpikeHandler.validate(action: candidate, userInfo: ["quickr": quickr])
                }
            }
        }
        quickr["version"] = 1
        #expect(throws: SpikeError.self) { try SpikeHandler.validate(action: garbage, userInfo: ["quickr": quickr]) }
        _ = try SpikeHandler.validate(action: action, userInfo: ["quickr": quickr])
    }

    @Test func defaultAndDismissActionsLogNothing() {
        #expect(!SpikeHandler.isLogAction("com.apple.UNNotificationDefaultActionIdentifier"))
        #expect(!SpikeHandler.isLogAction("com.apple.UNNotificationDismissActionIdentifier"))
        #expect(SpikeHandler.isLogAction("q1|s|t|1|mood|o|calm"))
    }
}
#endif
