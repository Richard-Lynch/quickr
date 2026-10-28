import Foundation
import QuickrCore

/// Why a server address didn't work, as onboarding and Settings say it.
public enum ConnectProblem: Error, Sendable, Hashable, CustomStringConvertible {
    /// No usable answer: offline, a wrong address, a timeout, a 5xx.
    case unreachable(String)
    /// Something answered, but not quickR (a login page or a redirect to one, a proxy, another
    /// site).
    case notQuickr
    /// 401 or 403: an access gate in front of quickR (Cloudflare Access) said no.
    case accessDenied(status: Int)
    /// quickR refused for another reason.
    case rejected(status: Int, message: String?)
    /// quickR answered with something this app can't read (an incompatible version).
    case protocolError(String)
    /// This device couldn't save the server's data.
    case storage(String)
    /// Another sync held the store; trying again works.
    case busy
    /// The server refuses this build (426 `client_outdated`, client-versions.md §4.1): it needs
    /// an update before it can connect.
    case clientOutdated(minimum: Int)

    public var description: String {
        switch self {
        case .unreachable:
            "Couldn’t reach the server. Check the address and that this iPhone is online (and on the same network, for a local address)."
        case .notQuickr:
            "Something answered at that address, but it isn’t quickR. If it’s behind Cloudflare Access, add a service token below."
        case .accessDenied(let status):
            "The server refused access (\(status)). If it’s behind Cloudflare Access, check the service token."
        case .rejected(let status, let message):
            "The server said no (\(status)\(message.map { ": \($0)" } ?? ""))."
        case .protocolError:
            "The server’s answer wasn’t understood. Is it running a recent quickR?"
        case .storage(let detail): "Couldn’t save on this iPhone: \(detail)"
        case .busy: "quickR is busy syncing. Try again in a moment."
        case .clientOutdated:
            "quickR needs an update to connect to this server. Update it from TestFlight, then connect again."
        }
    }

    /// The technical detail, for a "Details" disclosure. Never contains credentials.
    public var detail: String? {
        switch self {
        case .unreachable(let detail), .protocolError(let detail), .storage(let detail): detail
        case .rejected(_, let message): message
        case .notQuickr, .accessDenied, .busy, .clientOutdated: nil
        }
    }

    /// Whether a Cloudflare Access token may be what's missing.
    public var suggestsAccessToken: Bool {
        switch self {
        case .notQuickr, .accessDenied: true
        default: false
        }
    }

    init(_ failure: SyncFailure) {
        switch failure {
        case .unreachable(let detail): self = .unreachable(detail)
        case .protocolError(let detail): self = .protocolError(detail)
        case .rejected(let status, _) where status == 401 || status == 403: self = .accessDenied(status: status)
        case .rejected(let status, let message): self = .rejected(status: status, message: message)
        case .leaseBusy: self = .busy
        case .storage(let detail): self = .storage(detail)
        }
    }
}

/// A connect attempt, for the screen.
public enum ConnectOutcome: Sendable, Hashable {
    /// The server is active. `note` says the first sync didn't finish (it retries by itself).
    case connected(serverId: String, isNew: Bool, note: String?)
    case failed(ConnectProblem)
}

extension SyncCoordinator.ConnectResult {
    public var outcome: ConnectOutcome {
        switch self {
        case .connected(let serverId, let isNew, let sync):
            let note: String? =
                switch sync {
                case .failed(let failure):
                    "Connected, but loading your topics didn’t finish (\(ConnectProblem(failure).description)) It carries on by itself."
                default: nil
                }
            return .connected(serverId: serverId, isNew: isNew, note: note)
        case .failed(let failure): return .failed(ConnectProblem(failure))
        case .notQuickr: return .failed(.notQuickr)
        case .clientOutdated(let minimum): return .failed(.clientOutdated(minimum: minimum))
        }
    }
}

/// Which server answers at an address, without connecting to it (sync-protocol.md §8.4 step 1):
/// one feed item, read for its `server_id`.
public enum ServerProbe {
    public static func serverId(
        at baseURL: URL, transport: any Transport, credentials: any AccessCredentialsProvider
    ) async -> Result<String, ConnectProblem> {
        let client = APIClient(
            baseURL: baseURL, transport: transport, identity: StaticServerIdentity(nil), credentials: credentials)
        let response: APIResponse<ChangePage>
        do {
            response = try await client.listChanges(after: 0, limit: 1, options: RequestOptions(expecting: nil))
        } catch {
            return .failure(.unreachable(String(describing: error)))
        }
        // An access gate (Cloudflare Access) answers 401 or 403 without quickR's headers; the
        // classifier retries those, but here it's the answer to show.
        if let status = response.status, status == 401 || status == 403 {
            if case .success = response.outcome {} else { return .failure(.accessDenied(status: status)) }
        }
        // Cloudflare Access without a valid token (and not in strict mode) redirects to its login
        // page: something answered, and a token may be what's missing.
        if case .retryable(.redirect) = response.outcome { return .failure(.notQuickr) }
        switch response.outcome {
        case .success(let page): return .success(page.serverId)
        case .identityMismatch: return .failure(.notQuickr)
        case .clientOutdated(let minimum): return .failure(.clientOutdated(minimum: minimum))
        default:
            return .failure(SyncCoordinator.failure(response).map(ConnectProblem.init) ?? .unreachable("no page"))
        }
    }
}

extension AppSession {
    /// The server at `baseURL`, through this session's transport and Access credentials.
    public func probeServer(at baseURL: URL) async -> Result<String, ConnectProblem> {
        await ServerProbe.serverId(
            at: baseURL, transport: configuration.transport, credentials: configuration.credentials)
    }
}
