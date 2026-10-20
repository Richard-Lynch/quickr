import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// App settings (`/settings`): the server and switching it, the Cloudflare Access token, reminders,
/// resetting this iPhone's copy, and about.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var permission = NotificationPermission()
    @State private var reset: ResetFlow?
    @State private var changingServer: ServerSetup?
    @State private var editingToken = false
    @State private var token: AccessCredentials?
    @State private var tokenError: String?

    var body: some View {
        List {
            serverSection
            accessSection
            Section {
                NotificationExplainer(permission: permission)
                    .padding(.vertical, 4)
            }
            if let reset { ResetSection(flow: reset) }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .qrPaperBackground()
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings.list")
        .task {
            if reset == nil, let session = environment.session { reset = ResetFlow(session: session) }
            loadToken()
        }
        .sheet(item: $changingServer) { setup in
            NavigationStack {
                ScrollView {
                    ServerForm(setup: setup, connectLabel: "Switch").padding(20)
                }
                .qrPaperBackground()
                .navigationTitle("Change server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changingServer = nil } }
                }
                .onChange(of: setup.state) { _, state in
                    if case .connected = state {
                        loadToken()
                        changingServer = nil
                    }
                }
            }
        }
        .sheet(isPresented: $editingToken, onDismiss: loadToken) {
            AccessTokenEditor(credentials: environment.credentials, current: token)
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            LabeledContent("Address") {
                Text(environment.settings.serverURL?.absoluteString ?? "Not set")
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("settings.serverURL")
            }
            LabeledContent("Status", value: status)
            Button("Change server…") {
                guard let session = environment.session else { return }
                changingServer = ServerSetup(
                    session: session, settings: environment.settings, credentials: environment.credentials)
            }
            .disabled(environment.session == nil)
            .accessibilityIdentifier("settings.changeServer")
        } header: {
            Text("Server")
        } footer: {
            Text("Each server keeps its own data on this iPhone. Switching back picks up where you left off.")
        }
    }

    private var status: String {
        switch environment.session?.phase {
        case .ready: "Connected"
        case .noServer: "No server"
        case .failed(let message): "Error: \(message)"
        case .starting, nil: "Starting…"
        }
    }

    // MARK: - Cloudflare Access

    private var accessSection: some View {
        Section {
            if let token {
                LabeledContent("Client ID") {
                    Text(token.clientId).font(.qr(.monoCaption)).textSelection(.enabled)
                }
                .accessibilityIdentifier("settings.accessClientId")
                LabeledContent("Client Secret", value: "Stored in the Keychain")
                Button("Replace token…") { editingToken = true }
                Button("Remove token", role: .destructive) { removeToken() }
                    .accessibilityIdentifier("settings.removeToken")
            } else {
                Text("None. Only needed when the server is behind Cloudflare Access.")
                    .foregroundStyle(.qr.muted)
                Button("Add service token…") { editingToken = true }
                    .accessibilityIdentifier("settings.addToken")
            }
            if let tokenError {
                Text(tokenError).foregroundStyle(QuickrTone.danger.foreground)
            }
        } header: {
            Text("Cloudflare Access")
        } footer: {
            Text("Sent with every request as CF-Access-Client-Id and CF-Access-Client-Secret. Never synced or shared.")
        }
    }

    private func loadToken() {
        do {
            token = try environment.credentials?.stored()
            tokenError = nil
        } catch {
            tokenError = "Couldn’t read the Keychain: \(error)"
        }
    }

    private func removeToken() {
        do {
            try environment.credentials?.save(nil)
            loadToken()
        } catch {
            tokenError = "Couldn’t remove the token: \(error)"
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.appVersion)
                .accessibilityIdentifier("settings.version")
            LabeledContent("Core", value: QuickrCore.version)
            if let binding = environment.session?.binding {
                LabeledContent("Server ID") {
                    Text(binding.serverId).font(.qr(.monoCaption)).textSelection(.enabled)
                }
                LabeledContent("Local copy", value: "Generation \(binding.storeGen)")
            }
            Text("Fonts: Bricolage Grotesque, Instrument Sans and JetBrains Mono, under the SIL Open Font License 1.1.")
                .font(.qr(.footnote))
                .foregroundStyle(.qr.muted)
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Enter or replace the Cloudflare Access service token.
private struct AccessTokenEditor: View {
    let credentials: KeychainAccessCredentials?
    @State private var clientId: String
    @State private var clientSecret = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(credentials: KeychainAccessCredentials?, current: AccessCredentials?) {
        self.credentials = credentials
        _clientId = State(initialValue: current?.clientId ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID (….access)", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("token.clientId")
                    SecureField("Client Secret", text: $clientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("token.clientSecret")
                } footer: {
                    Text("From Cloudflare Zero Trust ▸ Access ▸ Service Auth. Stored only in this iPhone’s Keychain.")
                }
                if let error {
                    Text(error).foregroundStyle(QuickrTone.danger.foreground)
                }
            }
            .navigationTitle("Service token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("token.save")
                }
            }
        }
    }

    private func save() {
        switch AccessCredentials.validated(clientId: clientId, clientSecret: clientSecret) {
        case .success(let token?):
            do {
                try credentials?.save(token)
                dismiss()
            } catch {
                self.error = "Couldn’t save the token: \(error)"
            }
        case .success(nil):
            error = AccessCredentials.Problem.missingClientId.description
        case .failure(let problem):
            error = problem.description
        }
    }
}

extension ServerSetup: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
