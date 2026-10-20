import Foundation
import Observation
import QuickrCore
import QuickrData

/// Onboarding's and Settings' "connect to a server" (sync-protocol.md §2.1, §8.4): checks the
/// address and the optional Cloudflare Access token, saves the token to the Keychain, probes the
/// address for its `server_id`, warns before leaving unsynced changes behind on another server,
/// then connects (which switches stores) and remembers the address.
@MainActor @Observable
final class ServerSetup {
    enum State: Equatable {
        case editing
        case working(String)
        /// Switching would leave changes unsynced on the current server; the user decides.
        case confirmSwitch(SwitchWarning)
        case failed(Failure)
        case connected(note: String?)
    }

    struct SwitchWarning: Equatable {
        var target: URL
        var targetServerId: String
        var count: Int
        var failedCount: Int
        var oldServer: String
    }

    struct Failure: Equatable {
        var message: String
        var detail: String?
        var suggestsAccessToken: Bool
    }

    var address: String
    var clientId = ""
    var clientSecret = ""
    /// Show the Cloudflare Access fields (opened by the user, or by an error that suggests them).
    var showsAccessToken = false
    private(set) var state: State = .editing

    @ObservationIgnored let session: AppSession
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let credentials: KeychainAccessCredentials?

    init(session: AppSession, settings: AppSettings, credentials: KeychainAccessCredentials?) {
        self.session = session
        self.settings = settings
        self.credentials = credentials
        address = settings.serverURL?.absoluteString ?? ""
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// Back to editing after an error or a cancelled switch.
    func edit() {
        state = .editing
    }

    /// Checks, probes and connects. With unsynced changes on the current server and a different
    /// server at the address, stops at `.confirmSwitch` instead.
    func connect() async {
        let url: URL
        switch ServerAddress.parse(address) {
        case .success(let parsed): url = parsed
        case .failure(let problem):
            fail(problem.description)
            return
        }
        switch AccessCredentials.validated(clientId: clientId, clientSecret: clientSecret) {
        case .success(let token?):
            do {
                try credentials?.save(token)
            } catch {
                fail("Couldn’t save the token on this iPhone.", detail: String(describing: error))
                return
            }
        case .success(nil):
            break  // nothing typed: keep any token already stored
        case .failure(let problem):
            showsAccessToken = true
            fail(problem.description)
            return
        }
        state = .working("Checking the server…")
        let serverId: String
        switch await session.probeServer(at: url) {
        case .success(let id): serverId = id
        case .failure(let problem):
            fail(problem)
            return
        }
        if let current = session.binding, current.serverId != serverId,
            let warning = try? await session.coordinator.resetWarning(), warning.count > 0
        {
            state = .confirmSwitch(
                SwitchWarning(
                    target: url, targetServerId: serverId, count: warning.count, failedCount: warning.failedCount,
                    oldServer: current.baseURL.host() ?? current.baseURL.absoluteString))
            return
        }
        await finish(url)
    }

    /// The switch warning's choices: "Sync now" sends what it can first, "Switch anyway" doesn't.
    /// The state moves on before this returns; the work runs in a task.
    func confirmSwitch(syncFirst: Bool) {
        guard case .confirmSwitch(let warning) = state else { return }
        state = .working(syncFirst ? "Sending your changes…" : "Connecting…")
        Task {
            if syncFirst { _ = await session.scheduler?.flushNow(reason: .enqueue) }
            await finish(warning.target)
        }
    }

    private func finish(_ url: URL) async {
        state = .working("Connecting…")
        switch await session.connect(baseURL: url).outcome {
        case .connected(_, _, let note):
            settings.serverURL = url
            address = url.absoluteString
            clientSecret = ""
            state = .connected(note: note)
        case .failed(let problem):
            fail(problem)
        }
    }

    private func fail(_ problem: ConnectProblem) {
        if problem.suggestsAccessToken { showsAccessToken = true }
        state = .failed(
            Failure(
                message: problem.description, detail: problem.detail, suggestsAccessToken: problem.suggestsAccessToken))
    }

    private func fail(_ message: String, detail: String? = nil) {
        state = .failed(Failure(message: message, detail: detail, suggestsAccessToken: false))
    }
}
