import Foundation
import Observation
import QuickrCore
import QuickrData

/// What `ServerSetup` needs from the session (`AppSession` in the app, a fake in tests).
@MainActor
protocol ServerSwitcher: AnyObject {
    /// The active server's id and address, or nil before onboarding.
    var activeServer: (id: String, baseURL: URL)? { get }
    /// The server at `url`, asked with `credentials` (not the stored token).
    func probe(_ url: URL, credentials: any AccessCredentialsProvider) async -> Result<String, ConnectProblem>
    /// Unsynced changes on the active store, or nil with none active.
    func unsyncedChanges() async throws -> (count: Int, failed: Int)?
    /// Sends what can be sent now, with the active server's own token.
    func flush() async
    /// Connects (switching stores), sending the stored token.
    func connect(_ url: URL) async -> ConnectOutcome
}

extension AppSession: ServerSwitcher {
    var activeServer: (id: String, baseURL: URL)? { binding.map { ($0.serverId, $0.baseURL) } }

    func probe(_ url: URL, credentials: any AccessCredentialsProvider) async -> Result<String, ConnectProblem> {
        await ServerProbe.serverId(at: url, transport: configuration.transport, credentials: credentials)
    }

    func unsyncedChanges() async throws -> (count: Int, failed: Int)? {
        try await coordinator.resetWarning().map { ($0.count, $0.failedCount) }
    }

    func flush() async {
        _ = await scheduler?.flushNow(reason: .enqueue)
    }

    func connect(_ url: URL) async -> ConnectOutcome {
        await connect(baseURL: url).outcome
    }
}

/// Onboarding's and Settings' "connect to a server" (sync-protocol.md §2.1, §8.4): checks the
/// address and the optional Cloudflare Access token, probes the address for its `server_id`,
/// warns before leaving unsynced changes behind on another server, then connects (which switches
/// stores) and remembers the address.
///
/// Tokens are per server (`KeychainAccessCredentials`): a typed token only probes until the switch
/// is confirmed, then is stored for the new address (re-keyed to its `server_id` once connected).
/// The active server's token is never touched, and its requests (a flush during the switch
/// included) only ever carry its own.
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

    @ObservationIgnored let switcher: any ServerSwitcher
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let credentials: KeychainAccessCredentials?
    /// The typed token for the confirmed switch, held only in memory until the connect.
    @ObservationIgnored private var pendingToken: AccessCredentials?

    /// - Parameter defaultAddress: the address to offer before any is configured (onboarding):
    ///   the build's `QuickrDefaultServerURL`.
    init(
        switcher: any ServerSwitcher, settings: AppSettings, credentials: KeychainAccessCredentials?,
        defaultAddress: String = ServerSetup.defaultAddress()
    ) {
        self.switcher = switcher
        self.settings = settings
        self.credentials = credentials
        address = settings.serverURL?.absoluteString ?? defaultAddress
    }

    convenience init(session: AppSession, settings: AppSettings, credentials: KeychainAccessCredentials?) {
        self.init(switcher: session, settings: settings, credentials: credentials)
    }

    /// The build's default server address (Info.plist `QuickrDefaultServerURL`, from the
    /// `QUICKR_DEFAULT_SERVER_URL` build setting): the hosted server in Release, empty in Debug.
    /// Empty when it's missing, blank, or an unexpanded `$(…)`.
    nonisolated static func defaultAddress(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let value = (info?["QuickrDefaultServerURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.contains("$(") ? "" : value
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// Back to editing after an error or a cancelled switch. Nothing was stored.
    func edit() {
        pendingToken = nil
        state = .editing
    }

    /// Checks, probes and connects. With unsynced changes on the current server and a different
    /// server at the address, stops at `.confirmSwitch` instead.
    func connect() async {
        pendingToken = nil
        let url: URL
        switch ServerAddress.parse(address) {
        case .success(let parsed): url = parsed
        case .failure(let problem):
            fail(problem.description)
            return
        }
        let typed: AccessCredentials?
        switch AccessCredentials.validated(clientId: clientId, clientSecret: clientSecret) {
        case .success(let token): typed = token
        case .failure(let problem):
            showsAccessToken = true
            fail(problem.description)
            return
        }
        // The probe sends the typed token, or the stored one when nothing was typed.
        let probeToken: AccessCredentials?
        do {
            if let typed {
                probeToken = typed
            } else {
                probeToken = try await credentials?.stored(for: url)
            }
        } catch {
            fail("Couldn’t read the token from the Keychain.", detail: String(describing: error))
            return
        }
        state = .working("Checking the server…")
        let serverId: String
        switch await switcher.probe(url, credentials: StaticAccessCredentials(probeToken)) {
        case .success(let id): serverId = id
        case .failure(let problem):
            fail(problem)
            return
        }
        if let current = switcher.activeServer, current.id != serverId {
            let changes: (count: Int, failed: Int)?
            do {
                changes = try await switcher.unsyncedChanges()
            } catch {
                // Never switch without knowing what would be left behind.
                fail(
                    "Couldn’t check for changes that haven’t synced, so nothing was switched.",
                    detail: String(describing: error))
                return
            }
            if let changes, changes.count > 0 {
                pendingToken = typed
                state = .confirmSwitch(
                    SwitchWarning(
                        target: url, targetServerId: serverId, count: changes.count, failedCount: changes.failed,
                        oldServer: current.baseURL.host() ?? current.baseURL.absoluteString))
                return
            }
        }
        await finish(url, token: typed)
    }

    /// The switch warning's choices: "Sync now" sends what it can first (with the current server's
    /// own token), "Switch anyway" doesn't. The state moves on before this returns.
    func confirmSwitch(syncFirst: Bool) {
        guard case .confirmSwitch(let warning) = state else { return }
        let token = pendingToken
        pendingToken = nil
        state = .working(syncFirst ? "Sending your changes…" : "Connecting…")
        Task {
            if syncFirst { await switcher.flush() }
            await finish(warning.target, token: token)
        }
    }

    /// Stores `token` (if one was typed) for `url` only, connects, and on success files it under
    /// the server's id. A failed connect leaves every token as it was (and the typed one ready
    /// for a retry at that address).
    private func finish(_ url: URL, token: AccessCredentials?) async {
        state = .working("Connecting…")
        if let token {
            do {
                try await credentials?.save(token, for: url)
            } catch {
                fail("Couldn’t save the token on this iPhone.", detail: String(describing: error))
                return
            }
        }
        switch await switcher.connect(url) {
        case .connected(let serverId, _, let note):
            var note = note
            do {
                try credentials?.adopt(baseURL: url, serverId: serverId)
            } catch {
                // Not fatal: requests still find the token under the address.
                note = [note, "The token stays filed under this address (\(error))."].compactMap { $0 }.joined(
                    separator: " ")
            }
            settings.serverURL = url
            address = url.absoluteString
            // The typed token stays in the fields as the form goes, so iOS or a password manager
            // can offer to save it (AutoFill); quickR's own copy is the Keychain's. Safe because a
            // ServerSetup is never reused after `.connected`: one per form (onboarding's goes with
            // its view, Settings makes one per Change server sheet and closes it on connect). A
            // reused one would send this typed token with a later connect to another address.
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
