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
            return APIResponse(
                outcome: outcome, status: nil, observed: ObservedIdentity(serverId: nil, epoch: nil),
                expected: expected, bodyIsTrusted: false)
        case .success(let value):
            response = value
        }
        let observed = ObservedIdentity(response: response.headers)
        let outcome = classify(response, observed: observed, expected: expected, decode: decode)
        let trusted: Bool
        switch outcome {
        case .identityMismatch, .epochMismatch: trusted = false
        default: trusted = observed.complete != nil
        }
        return APIResponse(
            outcome: outcome, status: response.status, observed: observed, expected: expected, body: response.body,
            bodyIsTrusted: trusted)
    }

    private static func classify<Success: Sendable>(
        _ response: HTTPResponse, observed: ObservedIdentity, expected: ServerIdentity?,
        decode: (HTTPResponse) throws -> Success
    ) -> APIOutcome<Success> {
        let status = response.status
        let isSuccess = (200..<300).contains(status)

        // Step 0 (outbox.md §5.2, sync-protocol.md §1.4): headers before anything else. Each
        // present header is compared on its own, server first. A Problem (including the 409
        // precondition codes) is read only from a response that carries both headers.
        let identity = observed.complete
        let problem = isSuccess || identity == nil ? nil : try? Endpoints.decodeProblem(response.body)
        let code = status == 409 ? problem?.code : nil
        let rejected = code == .serverMismatch || code == .epochMismatch
        func evidence() -> MismatchEvidence {
            if rejected, let identity { return .preconditionRejected(observed: identity) }
            return .responseHeaders(observed: observed)
        }
        let serverDiffers =
            expected.map { expected in
                observed.serverId.map { $0.lowercased() != expected.serverId.lowercased() } ?? false
            } ?? false
        let epochDiffers =
            expected.map { expected in
                observed.epoch.map { $0.lowercased() != expected.epoch.lowercased() } ?? false
            } ?? false
        if serverDiffers || code == .serverMismatch { return .identityMismatch(evidence()) }
        if epochDiffers || code == .epochMismatch { return .epochMismatch(evidence()) }

        guard identity != nil else {
            // It never (provably) reached quickR's application logic: never read as an
            // application error.
            if isSuccess { return .identityMismatch(.missingHeaders(status: status, observed: observed)) }
            switch status {
            case 300..<400: return .retryable(.redirect(status: status))
            case 500..<600: return .uncertain(.serverError(status: status, problem: nil))
            case _ where retryable4xx.contains(status): return .retryable(.status(status, nil))
            default: return .retryable(.unexpectedResponse(status: status))
            }
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
