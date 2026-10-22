import Foundation
import QuickrData

/// Loads `shared/fixtures` straight from the repository checkout, so tests always see the
/// committed files and nothing is copied into a bundle.
///
/// The path comes from this source file's location (`#filePath`), which works for `swift test`
/// on the Mac and for the simulator, whose processes read the host file system. Set
/// `QUICKR_FIXTURES_DIR` to override it (for example on a device, after copying the files).
public enum Fixtures {
    public static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["QUICKR_FIXTURES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // <repo>/ios/QuickrKit/Sources/QuickrTestSupport/Fixtures.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("shared/fixtures", isDirectory: true)
    }()

    public enum LoadError: Error, CustomStringConvertible {
        case missing(URL)
        case malformed(String, any Error)

        public var description: String {
            switch self {
            case .missing(let url): "fixture not found: \(url.path) (set QUICKR_FIXTURES_DIR?)"
            case .malformed(let name, let error): "fixture \(name) is malformed: \(error)"
            }
        }
    }

    /// Raw bytes of a file under `shared/fixtures`, for example `due-vectors.json`.
    public static func data(_ relativePath: String) throws -> Data {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing(url) }
        return try Data(contentsOf: url)
    }

    /// `due-vectors.json` (decoded by the DUE port).
    public static func dueVectors() throws -> Data { try data("due-vectors.json") }

    /// `quicklog-vectors.json` (decoded by the VAL port).
    public static func quicklogVectors() throws -> Data { try data("quicklog-vectors.json") }

    /// The names of every `api/*.json` fixture without the extension, sorted, for example
    /// `createEntry.entry_deleted`.
    public static func apiNames() throws -> [String] {
        let directory = root.appendingPathComponent("api", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw LoadError.missing(directory) }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    public static func api(_ name: String) throws -> APIFixture {
        let raw = try data("api/\(name).json")
        do {
            return try APIFixture(name: name, json: raw)
        } catch {
            throw LoadError.malformed(name, error)
        }
    }

    public static func allAPI() throws -> [APIFixture] { try apiNames().map(api) }
}

/// One recorded API call: `{operation_id, request: {method, path, body}, status, body}`
/// (shared/fixtures/README.md). Bodies are kept as raw JSON bytes; `nil` when the fixture has
/// `null` (a 204, or a request without a body).
public struct APIFixture: Sendable, Hashable {
    public var name: String
    public var operationId: String
    public var method: String
    /// Path and query, for example `/api/v1/changes?after=0&limit=500`.
    public var path: String
    public var requestBody: Data?
    public var status: Int
    public var body: Data?

    public var isSuccess: Bool { (200..<300).contains(status) }

    init(name: String, json: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
            let operationId = object["operation_id"] as? String, let status = object["status"] as? Int,
            let request = object["request"] as? [String: Any], let method = request["method"] as? String,
            let path = request["path"] as? String
        else { throw Fixtures.LoadError.missing(URL(fileURLWithPath: name)) }
        self.name = name
        self.operationId = operationId
        self.method = method
        self.path = path
        self.status = status
        self.requestBody = try Self.reencode(request["body"])
        self.body = try Self.reencode(object["body"])
    }

    private static func reencode(_ value: Any?) throws -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    /// The fixture as a transport response, with the F9 identity headers.
    public func response(
        serverId: String = "00000000-0000-4000-8000-000000000009",
        epoch: String = "00000000-0000-4000-8000-000000000008"
    ) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: [QuickrHeader.serverId: serverId, QuickrHeader.epoch: epoch],
            body: body ?? Data())
    }
}
