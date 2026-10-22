import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// Copied into an OLD client's QuickrDataTests by compat/old-client.sh, so it must compile against
/// every client in compat/supported-clients.json: it uses only API they all have.
///
/// Each vector case the client predates (`fallbacks` in the policy) must take the fallback
/// declared for it, through the client's production code, never fail (docs/ios/specs/compatibility.md §3):
/// - `unread`: `userInfo.quickr` doesn't decode, so iOS shows the server's alert as it is (no
///   actions, no quickR handling). What builds before the f4ed020 fallback do.
/// - `plain`: it decodes with no quick_log, a plain reminder (f4ed020 and later).
/// - `no-category`: the client builds no category for the topic, so the server's category id
///   matches nothing it registered and iOS shows the alert without actions.
@Suite struct CompatFallbackTests {
    struct Fallback: Sendable, CustomTestStringConvertible {
        var file: String
        var name: String
        var expect: String
        /// The case as the fixtures hold it.
        var raw: Data

        var payload: [String: Any] { (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:] }
        var testDescription: String { "\(file) \(name): \(expect)" }
    }

    static let fallbacks: [Fallback] = {
        guard let path = ProcessInfo.processInfo.environment["QUICKR_COMPAT_FALLBACKS"] else {
            fatalError("QUICKR_COMPAT_FALLBACKS isn't set (compat/old-client.sh sets it)")
        }
        do {
            let list = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let items = list as? [[String: Any]] else { fatalError("\(path): not a list of objects") }
            return try items.map { item in
                guard let file = item["file"] as? String, let name = item["name"] as? String,
                    let expect = item["expect"] as? String, let body = item["case"]
                else { fatalError("\(path): \(item) lacks file, name, expect or case") }
                return Fallback(
                    file: file, name: name, expect: expect, raw: try JSONSerialization.data(withJSONObject: body))
            }
        } catch {
            fatalError("\(path): \(error)")
        }
    }()

    @Test func theListIsRead() {
        _ = Self.fallbacks
    }

    @Test(arguments: fallbacks)
    func takesItsFallback(_ fallback: Fallback) throws {
        let label = "\(fallback.file) \(fallback.name)"
        switch fallback.expect {
        case "unread", "plain":
            let expected = try #require(fallback.payload["expected"] as? [String: Any], "\(label): no expected")
            let quickr = try #require(expected["quickr"], "\(label): no expected.quickr")
            let info = QuickrNotificationInfo(userInfo: ["quickr": quickr])
            if fallback.expect == "unread" {
                #expect(info == nil, "\(label): the client reads it (\(String(describing: info))): declare plain")
            } else {
                #expect(info != nil, "\(label): the client can't read the payload")
                #expect(info?.quickLog == nil, "\(label): the client reads a quick_log it should ignore")
            }
        case "no-category":
            let vector = try JSONDecoder().decode(CategoryInput.self, from: fallback.raw)
            let category = NotificationCategory(
                serverId: vector.serverId, topicId: vector.topicId, version: vector.version,
                questions: vector.questions.map { $0.toDomain() }, counts: vector.counts, last: vector.last)
            #expect(category == nil, "\(label): the client builds category \(category?.id ?? "")")
        default:
            Issue.record("\(label): unknown fallback \(fallback.expect)")
        }
    }

    /// The inputs of a notification-vectors.json case.
    struct CategoryInput: Decodable {
        var serverId: String
        var topicId: String
        var version: Int
        var questions: [QuestionDTO]
        var counts: [String: Int]
        var last: AnswerValue?

        enum CodingKeys: String, CodingKey {
            case version, questions, counts, last
            case serverId = "server_id"
            case topicId = "topic_id"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            serverId = try c.decode(String.self, forKey: .serverId)
            topicId = try c.decode(String.self, forKey: .topicId)
            version = try c.decode(Int.self, forKey: .version)
            questions = try c.decode([QuestionDTO].self, forKey: .questions)
            counts = try c.decode([String: Int].self, forKey: .counts)
            if try !c.contains(.last) || c.decodeNil(forKey: .last) {
                last = nil
            } else if let n = try? c.decode(Int.self, forKey: .last) {
                last = .int(n)
            } else {
                last = .double(try c.decode(Double.self, forKey: .last))
            }
        }
    }
}
