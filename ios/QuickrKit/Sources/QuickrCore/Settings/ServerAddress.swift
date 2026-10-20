import Foundation

/// The server address typed during onboarding or in Settings, checked before anything connects.
///
/// Accepts what people paste: surrounding spaces, no scheme (`quickr.example.com` means
/// `https://`), a trailing slash, the PWA's own pages (`…/t/water` or `…/settings`, cut back to
/// the base) or the API root (`…/api/v1`). A path prefix stays (a reverse proxy at
/// `https://nas.local/quickr`). Plain `http://` is only allowed for local addresses, which is all
/// App Transport Security lets through (`NSAllowsLocalNetworking`).
public enum ServerAddress {
    public enum Problem: Error, Sendable, Hashable, CustomStringConvertible {
        case empty
        case malformed
        case unsupportedScheme(String)
        case insecure
        case hasCredentials
        case hasQueryOrFragment

        public var description: String {
            switch self {
            case .empty: "Enter your quickR server’s address."
            case .malformed: "That isn’t a web address. It looks like https://quickr.example.com."
            case .unsupportedScheme(let scheme): "Use an https:// address (not \(scheme)://)."
            case .insecure:
                "Use https://. Plain http:// only works for addresses on your local network (like http://nas.local:8100)."
            case .hasCredentials: "Leave the user name and password out of the address."
            case .hasQueryOrFragment: "Leave out everything after ? or #."
            }
        }
    }

    /// The base URL to connect to: scheme, host, port and path prefix, with no trailing slash.
    public static func parse(_ text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.contains(where: \.isWhitespace) else { return .failure(.malformed) }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme), let scheme = components.scheme?.lowercased()
        else { return .failure(.malformed) }
        guard scheme == "https" || scheme == "http" else { return .failure(.unsupportedScheme(scheme)) }
        guard let host = components.host?.lowercased(), !host.isEmpty, isHostname(host) else {
            return .failure(.malformed)
        }
        guard components.user == nil, components.password == nil else { return .failure(.hasCredentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQueryOrFragment) }
        if scheme == "http" && !isLocal(host) { return .failure(.insecure) }
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = basePath(components.percentEncodedPath)
        guard let url = components.url else { return .failure(.malformed) }
        return .success(url)
    }

    /// Whether `http://` reaches `host`: loopback, `.local` names, single-label names and
    /// private or link-local IPv4 addresses.
    public static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) {
            let a = octets[0]!
            let b = octets[1]!
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254)
        }
        // A single-label name ("nas") only resolves on the local network.
        return !host.contains(".") && !host.contains(":")
    }

    /// Drops a trailing slash, and a PWA page or the API root at the end of the path, so a link
    /// copied from the browser connects to the server itself.
    static func basePath(_ path: String) -> String {
        var segments = path.split(separator: "/").map(String.init)
        if let i = segments.lastIndex(of: "api"), segments.count == i + 2, segments[i + 1] == "v1" {
            segments.removeSubrange(i...)
        } else if let i = segments.firstIndex(of: "t"), i + 1 < segments.count,
            DeepLink.routes(forPath: "/" + segments[i...].joined(separator: "/")) != nil
        {
            segments.removeSubrange(i...)
        } else if let last = segments.last, ["settings", "new"].contains(last) {
            segments.removeLast()
        }
        return segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    }

    private static func isHostname(_ host: String) -> Bool {
        if host.hasPrefix("[") { return host.hasSuffix("]") }
        return host.unicodeScalars.allSatisfy { c in
            CharacterSet.alphanumerics.contains(c) || c == "-" || c == "." || c == "_"
        } && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
}
