import Foundation

/// Requests and responses print and reflect with credential headers hidden, so the Cloudflare
/// Access secret (or any other credential) never reaches a log, a test failure message or a crash
/// report through `"\(request)"`, `String(reflecting:)` or `dump`. `HTTPHeaders.all` still gives
/// the real values to the code that sends them.
extension HTTPHeaders: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let redactedValue = "<redacted>"

    /// Credential headers: `CF-Access-Client-Secret`, `Authorization`, cookies, and any name that
    /// says secret, token, password or key.
    public static func isSensitive(_ name: String) -> Bool {
        let name = name.lowercased()
        let exact: Set<String> = [
            QuickrHeader.cfAccessClientSecret.lowercased(), "authorization", "proxy-authorization", "cookie",
            "set-cookie", "cf-access-jwt-assertion",
        ]
        if exact.contains(name) { return true }
        return ["secret", "token", "password", "passwd", "api-key", "apikey", "auth"].contains { name.contains($0) }
    }

    /// Every field, with sensitive values replaced.
    public var redacted: [String: String] {
        all.reduce(into: [:]) { out, field in
            out[field.key] = Self.isSensitive(field.key) ? Self.redactedValue : field.value
        }
    }

    public var description: String {
        let fields = redacted.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return "[" + fields.joined(separator: ", ") + "]"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self, children: redacted.sorted { $0.key < $1.key }.map { (label: $0.key, value: $0.value as Any) },
            displayStyle: .dictionary)
    }
}

extension HTTPRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "\(method.rawValue) \(url.absoluteString) headers: \(headers) body: \(body?.count ?? 0) bytes"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "method": method, "url": url, "headers": headers, "bodyBytes": body?.count ?? 0, "timeout": timeout,
            ])
    }
}

extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "\(status) headers: \(headers) body: \(body.count) bytes" }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["status": status, "headers": headers, "bodyBytes": body.count])
    }
}
