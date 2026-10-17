import Foundation
import QuickrCore

/// A server's identity on the wire: `X-QuickR-Server-Id` and `X-QuickR-Epoch` on a response (F9),
/// or `X-QuickR-Expect-Server-Id` and `X-QuickR-Expect-Epoch` on a mutation (F10).
public struct ServerIdentity: Sendable, Hashable {
    public var serverId: String
    public var epoch: String

    public init(serverId: String, epoch: String) {
        self.serverId = serverId
        self.epoch = epoch
    }

    /// Both headers of a response; nil when either is missing or empty.
    public init?(response headers: HTTPHeaders) {
        guard let serverId = headers[QuickrHeader.serverId], let epoch = headers[QuickrHeader.epoch],
            !serverId.isEmpty, !epoch.isEmpty
        else { return nil }
        self.init(serverId: serverId, epoch: epoch)
    }

    func sameServer(as other: ServerIdentity) -> Bool { serverId.lowercased() == other.serverId.lowercased() }

    func sameEpoch(as other: ServerIdentity) -> Bool { epoch.lowercased() == other.epoch.lowercased() }
}

/// What one API call means for its caller: outbox.md §5.1 (the PWA's classification) after the
/// identity checks of §5.2 step 0 and sync-protocol.md §1.4.
///
/// Every case except `success` carries only what its headers allow to be trusted: a Problem is
/// decoded only from a response whose identity headers are present and match, so a 404 or a 409
/// here always comes from the expected server and epoch. Per-kind meaning (outbox.md §5.2 step 1,
/// for example "404 on `entry.update` means the entry is gone") is the caller's.
///
/// | Response                                                        | Outcome                                  |
/// | --------------------------------------------------------------- | ---------------------------------------- |
/// | No response, request not started (offline, DNS, TLS)            | `retryable(.noResponse)`                 |
/// | No response after the request started (timeout, lost, cancel)   | `uncertain(.noResponse)`                 |
/// | 2xx without the identity headers                                | `identityMismatch(.missingHeaders)`      |
/// | Non-2xx without the headers: 3xx                                | `retryable(.redirect)`                   |
/// | Non-2xx without the headers: 401, 403, 408, 425, 429            | `retryable(.status)`, no Problem         |
/// | Non-2xx without the headers: 5xx                                | `uncertain(.serverError)`, no Problem    |
/// | Non-2xx without the headers: anything else                      | `retryable(.unexpectedResponse)`         |
/// | 409 `server_mismatch`                                           | `identityMismatch(.preconditionRejected)`|
/// | Server header differs from the expected identity                | `identityMismatch(.responseHeaders)`     |
/// | 409 `epoch_mismatch`                                            | `epochMismatch(.preconditionRejected)`   |
/// | Epoch header differs from the expected identity                 | `epochMismatch(.responseHeaders)`        |
/// | 2xx that decodes as the operation's type                        | `success`                                |
/// | 2xx that doesn't (not JSON, captive portal, missing fields)     | `uncertain(.undecodableSuccess)`         |
/// | 3xx                                                             | `retryable(.redirect)`                   |
/// | 401, 403, 408, 425, 429                                         | `retryable(.status)`                     |
/// | 404                                                             | `notFound`                               |
/// | 409 `entry_deleted`                                             | `entryDeleted`                           |
/// | 409 `stale_revision`                                            | `staleRevision`                          |
/// | Any other 4xx                                                   | `terminal`                               |
/// | 5xx                                                             | `uncertain(.serverError)`                |
/// | Any other status (1xx, 6xx…)                                    | `retryable(.unexpectedResponse)`         |
///
/// The rows are checked top to bottom. Without an expected identity (before the store is
/// bootstrapped) the two header comparisons are skipped; the missing-header rows still apply.
public enum APIOutcome<Success: Sendable>: Sendable {
    /// A 2xx from the expected server and epoch whose body decoded and mapped to the domain.
    case success(Success)
    /// Retry later; `maybe_delivered` is unchanged (outbox.md §5.1 "unchanged" rows): the request
    /// never left, or the response proves it didn't execute.
    case retryable(RetryReason)
    /// Retry later, and set `maybe_delivered` (S3): the request may have executed.
    case uncertain(UncertainReason)
    /// A 4xx that retrying can never fix (other than 404 and the 409 codes below): 400, 409
    /// `conflict` or `topic_archived` or `incompatible_version`, 422 `invalid_answers` or
    /// `invalid_request`, and any other code.
    case terminal(status: Int, problem: Problem?)
    /// 404 from the expected server and epoch. What is missing depends on the operation.
    case notFound(Problem?)
    /// 409 `entry_deleted`: the entry id was deleted or reserved and can never be created or
    /// changed (§6a rule 2).
    case entryDeleted(Problem)
    /// 409 `stale_revision`: `expected_revision` didn't match; rebase (outbox.md §7.4).
    case staleRevision(Problem)
    /// The response is from another server, or a 2xx came without identity headers. Never
    /// interpret it; the store enters identity mismatch (sync-protocol.md §8.3).
    case identityMismatch(MismatchEvidence)
    /// The response is from another epoch. Never interpret it; set `epoch_suspect`
    /// (sync-protocol.md §5.6).
    case epochMismatch(MismatchEvidence)

    /// The outbox's retry class (S4): `retryable` and `uncertain`.
    public var isRetry: Bool {
        switch self {
        case .retryable, .uncertain: true
        default: false
        }
    }

    /// Whether the request may have executed without a definitive answer, so an outbox item's
    /// `maybe_delivered` becomes 1 (S3).
    public var setsMaybeDelivered: Bool {
        switch self {
        case .uncertain: true
        case .identityMismatch(let evidence), .epochMismatch(let evidence): evidence.mayHaveExecuted
        default: false
        }
    }

    /// Whether a flush pass stops here (outbox.md §5.1 "stop the pass", §5.2 mismatches).
    public var stopsPass: Bool {
        switch self {
        case .retryable(.noResponse), .uncertain(.noResponse), .identityMismatch, .epochMismatch: true
        default: false
        }
    }

    /// The Problem, for the outcomes that carry one.
    public var problem: Problem? {
        switch self {
        case .terminal(_, let problem), .notFound(let problem): problem
        case .entryDeleted(let problem), .staleRevision(let problem): problem
        case .retryable(.status(_, let problem)), .uncertain(.serverError(_, let problem)): problem
        default: nil
        }
    }

    /// The same outcome with the success value transformed.
    public func map<Other: Sendable>(_ transform: (Success) throws -> Other) rethrows -> APIOutcome<Other> {
        switch self {
        case .success(let value): .success(try transform(value))
        case .retryable(let reason): .retryable(reason)
        case .uncertain(let reason): .uncertain(reason)
        case .terminal(let status, let problem): .terminal(status: status, problem: problem)
        case .notFound(let problem): .notFound(problem)
        case .entryDeleted(let problem): .entryDeleted(problem)
        case .staleRevision(let problem): .staleRevision(problem)
        case .identityMismatch(let evidence): .identityMismatch(evidence)
        case .epochMismatch(let evidence): .epochMismatch(evidence)
        }
    }
}

extension APIOutcome: Equatable where Success: Equatable {}
extension APIOutcome: Hashable where Success: Hashable {}

/// Why a `retryable` outcome is safe to resend without marking the request maybe-delivered.
public enum RetryReason: Sendable, Hashable {
    /// No response, and the request never left (`TransportError.requestStarted` is false).
    case noResponse(TransportError)
    /// A 3xx: never followed (a sign-in proxy bouncing to its login page).
    case redirect(status: Int)
    /// 401, 403, 408, 425 or 429. The Problem is nil when the identity headers were missing (an
    /// Access proxy's 403 page is never read as quickR's).
    case status(Int, Problem?)
    /// A status that can't be classified: a non-2xx without the identity headers outside the
    /// base table's retry rows, or a status outside 2xx–5xx.
    case unexpectedResponse(status: Int)
}

/// Why an `uncertain` outcome may have executed.
public enum UncertainReason: Sendable, Hashable {
    /// No response after the request started: a timeout, a dropped connection, cancellation.
    case noResponse(TransportError)
    /// A 5xx. The Problem is nil when the identity headers were missing.
    case serverError(status: Int, problem: Problem?)
    /// A 2xx whose body isn't JSON, doesn't decode or doesn't map (a captive portal's HTML page,
    /// a proxy's empty 200). The request may have committed.
    case undecodableSuccess(status: Int, reason: String)
}

/// What shows that a response came from the wrong server or epoch.
public enum MismatchEvidence: Sendable, Hashable {
    /// 409 `server_mismatch` or `epoch_mismatch`: the F10 precondition rejected the mutation
    /// before any effect. **Nothing executed**: restore the item's pre-claim state.
    case preconditionRejected(observed: ServerIdentity?)
    /// The response headers name another server or epoch. The request may have executed.
    case responseHeaders(observed: ServerIdentity)
    /// A 2xx without the identity headers (only ever an identity mismatch). It may have executed.
    case missingHeaders(status: Int)

    public var mayHaveExecuted: Bool {
        if case .preconditionRejected = self { return false }
        return true
    }
}

/// One API call's result: the outcome plus what the outbox records (`last_error_json`) and what
/// sync adopts (the response identity).
public struct APIResponse<Success: Sendable>: Sendable {
    public var outcome: APIOutcome<Success>
    /// The HTTP status; nil when no response arrived.
    public var status: Int?
    /// The response's identity headers, when both were present (whatever the outcome).
    public var identity: ServerIdentity?
    /// The identity the response was checked against: the mutation's expectation, or the
    /// store's identity for a read. Nil before bootstrap.
    public var expected: ServerIdentity?
    /// The raw response body (empty when no response arrived).
    public var body: Data

    public init(
        outcome: APIOutcome<Success>, status: Int?, identity: ServerIdentity?, expected: ServerIdentity?,
        body: Data = Data()
    ) {
        self.outcome = outcome
        self.status = status
        self.identity = identity
        self.expected = expected
        self.body = body
    }

    /// The success value, if any.
    public var value: Success? {
        if case .success(let value) = outcome { return value }
        return nil
    }

    /// The user-facing failure text: the PWA's `errorMessageFor` and `attempt()` strings
    /// (outbox.md §5.1). Nil for a success.
    public var message: String? {
        switch outcome {
        case .success: nil
        case .retryable(.noResponse), .uncertain(.noResponse): "Could not reach the server"
        case .retryable(.redirect): "The server redirected the request (sign-in required?)"
        case .retryable(.unexpectedResponse), .uncertain(.undecodableSuccess):
            "Unexpected response from the server"
        case .identityMismatch: "The server address now reaches a different quickR server"
        case .epochMismatch: "The server's data was restored or reset"
        default: Self.errorMessage(status: status ?? 0, body: body)
        }
    }

    /// `last_error_json` for an outbox item (`{message, status, body?}`, the PWA `OutboxError`).
    /// Nil for a success.
    public var errorInfo: OutboxErrorInfo? {
        guard let message else { return nil }
        let json = body.isEmpty ? nil : try? WireCoding.decoder().decode(JSONValue.self, from: body)
        return OutboxErrorInfo(message: message, status: status, body: json)
    }

    /// `errorMessageFor(status, body)`: the trimmed, capitalised `detail` of a JSON body, else
    /// "Server error (n)" or "Request failed (n)".
    static func errorMessage(status: Int, body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let detail = (object["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let first = detail.first
        {
            return first.uppercased() + detail.dropFirst()
        }
        return status >= 500 ? "Server error (\(status))" : "Request failed (\(status))"
    }
}
