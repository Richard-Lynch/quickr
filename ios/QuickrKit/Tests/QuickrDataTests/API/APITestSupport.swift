import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport

/// Shared values for the API tests.
enum APITest {
    /// The identity in `APIFixture.response()`'s default headers.
    static let fixtureIdentity = ServerIdentity(
        serverId: "00000000-0000-4000-8000-000000000009", epoch: "00000000-0000-4000-8000-000000000008")
    static let otherServer = "99999999-9999-4999-8999-999999999999"
    static let otherEpoch = "88888888-8888-4888-8888-888888888888"
    static let baseURL = URL(string: "https://quickr.example.com")!

    static func client(
        _ transport: any Transport, identity: ServerIdentity? = fixtureIdentity, credentials: AccessCredentials? = nil,
        origin: OutboxOrigin = .app, baseURL: URL = baseURL
    ) -> APIClient {
        APIClient(
            baseURL: baseURL, transport: transport, identity: StaticServerIdentity(identity),
            credentials: StaticAccessCredentials(credentials), origin: origin)
    }

    /// A response with the fixture identity headers (or `identity`, or none).
    static func response(
        _ status: Int, json: String? = nil, identity: ServerIdentity? = fixtureIdentity,
        headers extra: [String: String] = [:]
    ) -> HTTPResponse {
        var headers = HTTPHeaders(extra)
        if let identity {
            headers[QuickrHeader.serverId] = identity.serverId
            headers[QuickrHeader.epoch] = identity.epoch
        }
        if json != nil, headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        return HTTPResponse(status: status, headers: headers, body: Data((json ?? "").utf8))
    }

    static func problem(_ code: String, _ detail: String = "something happened") -> String {
        #"{"code": "\#(code)", "detail": "\#(detail)", "errors": []}"#
    }
}

/// JSON rendered exactly like the backend's `dump_json` (`json.dumps(indent=2, sort_keys=True,
/// ensure_ascii=False)` plus a newline), so generated files read like the other fixtures.
enum CanonicalJSON {
    static func render(_ value: Any) -> String { render(value, indent: "") + "\n" }

    static func render(data: Data) throws -> String {
        render(try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
    }

    private static func render(_ value: Any, indent: String) -> String {
        let inner = indent + "  "
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return quote(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                return double == double.rounded() && abs(double) < 1e16 ? String(format: "%.1f", double) : "\(double)"
            }
            return number.stringValue
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            return "[\n" + array.map { inner + render($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let object as [String: Any]:
            if object.isEmpty { return "{}" }
            let fields = object.keys.sorted {
                Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value))
            }
            .map { inner + quote($0) + ": " + render(object[$0]!, indent: inner) }
            return "{\n" + fields.joined(separator: ",\n") + "\n\(indent)}"
        default:
            preconditionFailure("not JSON: \(value)")
        }
    }

    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
