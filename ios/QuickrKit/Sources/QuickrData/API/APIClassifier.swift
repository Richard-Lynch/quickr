import Foundation
import QuickrCore

/// Turns a transport result into an `APIResponse`, following the table on `APIOutcome`.
///
/// Pure: no I/O, no state. `decode` reads a 2xx (including its headers, for the CSV export's
/// content type) and runs only once the identity checks have passed.
public enum APIClassifier {
    /// 4xx statuses worth retrying (the PWA's `RETRYABLE_4XX`): an auth proxy may come back after
    /// a re-login; 408, 425 and 429 are timeouts and rate limits.
    public static let retryable4xx: Set<Int> = [401, 403, 408, 425, 429]

    public static func classify<Success: Sendable>(
        _ result: Result<HTTPResponse, TransportError>, expected: ServerIdentity?,
        decode: (HTTPResponse) throws -> Success
    ) -> APIResponse<Success> {
        let response: HTTPResponse
        switch result {
        case .failure(let error):
            let outcome: APIOutcome<Success> =
                error.requestStarted ? .uncertain(.noResponse(error)) : .retryable(.noResponse(error))
            return APIResponse(outcome: outcome, status: nil, identity: nil, expected: expected)
        case .success(let value):
            response = value
        }
        let identity = ServerIdentity(response: response.headers)
        let outcome = classify(response, identity: identity, expected: expected, decode: decode)
        return APIResponse(
            outcome: outcome, status: response.status, identity: identity, expected: expected, body: response.body)
    }

    private static func classify<Success: Sendable>(
        _ response: HTTPResponse, identity: ServerIdentity?, expected: ServerIdentity?,
        decode: (HTTPResponse) throws -> Success
    ) -> APIOutcome<Success> {
        let status = response.status
        let isSuccess = (200..<300).contains(status)

        // Step 0 (outbox.md §5.2, sync-protocol.md §1.4): headers before anything else.
        guard let identity else {
            // It never reached quickR's application logic: never read as an application error.
            if isSuccess { return .identityMismatch(.missingHeaders(status: status)) }
            switch status {
            case 300..<400: return .retryable(.redirect(status: status))
            case 500..<600: return .uncertain(.serverError(status: status, problem: nil))
            case _ where retryable4xx.contains(status): return .retryable(.status(status, nil))
            default: return .retryable(.unexpectedResponse(status: status))
            }
        }
        let problem = isSuccess ? nil : try? Endpoints.decodeProblem(response.body)
        if status == 409, problem?.code == .serverMismatch {
            return .identityMismatch(.preconditionRejected(observed: identity))
        }
        if let expected, !identity.sameServer(as: expected) {
            return .identityMismatch(.responseHeaders(observed: identity))
        }
        if status == 409, problem?.code == .epochMismatch {
            return .epochMismatch(.preconditionRejected(observed: identity))
        }
        if let expected, !identity.sameEpoch(as: expected) {
            return .epochMismatch(.responseHeaders(observed: identity))
        }

        // §5.1, with the 404 and 409 codes the per-kind overrides need split out.
        switch status {
        case 200..<300:
            do {
                return .success(try decode(response))
            } catch {
                return .uncertain(.undecodableSuccess(status: status, reason: String(describing: error)))
            }
        case 300..<400:
            return .retryable(.redirect(status: status))
        case _ where retryable4xx.contains(status):
            return .retryable(.status(status, problem))
        case 404:
            return .notFound(problem)
        case 409:
            if let problem, problem.code == .entryDeleted { return .entryDeleted(problem) }
            if let problem, problem.code == .staleRevision { return .staleRevision(problem) }
            return .terminal(status: status, problem: problem)
        case 400..<500:
            return .terminal(status: status, problem: problem)
        case 500..<600:
            return .uncertain(.serverError(status: status, problem: problem))
        default:
            return .retryable(.unexpectedResponse(status: status))
        }
    }
}
