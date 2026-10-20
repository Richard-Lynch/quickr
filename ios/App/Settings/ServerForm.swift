import QuickrCore
import QuickrUI
import SwiftUI

/// The address field, the optional Cloudflare Access token, what went wrong, and Connect. Shared
/// by onboarding and Settings ▸ Change server; `ServerSetup` does the work.
struct ServerForm: View {
    @Bindable var setup: ServerSetup
    var connectLabel = "Connect"
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address, clientId, clientSecret
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server address")
                    .font(.qr(.label))
                    .foregroundStyle(.qr.ink)
                TextField("https://quickr.example.com", text: $setup.address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .focused($focus, equals: .address)
                    .modifier(FieldStyle(isInvalid: isFailed))
                    .accessibilityIdentifier("server.address")
                Text("The address you open quickR at in a browser.")
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
            }

            DisclosureGroup(isExpanded: $setup.showsAccessToken) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "For a server behind Cloudflare Access: a service token’s Client ID and Secret. They stay in this iPhone’s Keychain."
                    )
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                    TextField("Client ID (….access)", text: $setup.clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .clientId)
                        .modifier(FieldStyle(isInvalid: false))
                        .accessibilityIdentifier("server.clientId")
                    SecureField("Client Secret", text: $setup.clientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .clientSecret)
                        .modifier(FieldStyle(isInvalid: false))
                        .accessibilityIdentifier("server.clientSecret")
                }
                .padding(.top, 8)
            } label: {
                Text("Cloudflare Access token")
                    .font(.qr(.callout))
                    .foregroundStyle(.qr.inkSoft)
            }
            .tint(.qr.inkSoft)
            .accessibilityIdentifier("server.accessToken")

            status

            PrimaryButton(connectLabel, icon: .check, isLoading: setup.isWorking, action: connect)
                .accessibilityIdentifier("server.connect")
        }
        .confirmationDialog(
            switchTitle, isPresented: switchPresented, titleVisibility: .visible, presenting: switchWarning
        ) { _ in
            Button("Sync now, then switch") { setup.confirmSwitch(syncFirst: true) }
            Button("Switch anyway", role: .destructive) { setup.confirmSwitch(syncFirst: false) }
            Button("Cancel", role: .cancel) { setup.edit() }
        } message: { warning in
            Text(
                "\(changes(warning.count)) haven’t synced to \(warning.oldServer)\(warning.failedCount > 0 ? " (\(warning.failedCount) failed)" : ""). They stay on this iPhone and sync when you switch back."
            )
        }
    }

    @ViewBuilder
    private var status: some View {
        switch setup.state {
        case .working(let message):
            Label(message, systemImage: "hourglass")
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
                .accessibilityIdentifier("server.progress")
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    QIcon.alert.view(size: 15, weight: .bold)
                    Text(failure.message)
                        .font(.qr(.callout))
                }
                if let detail = failure.detail {
                    DisclosureGroup("Details") {
                        Text(detail)
                            .font(.qr(.monoCaption))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.qr(.subheadline))
                }
            }
            .foregroundStyle(QuickrTone.danger.foreground)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                QuickrTone.danger.background,
                in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("server.error")
        case .connected(let note?):
            Text(note)
                .font(.qr(.subheadline))
                .foregroundStyle(QuickrTone.warn.foreground)
                .accessibilityIdentifier("server.note")
        default:
            EmptyView()
        }
    }

    private var isFailed: Bool {
        if case .failed = setup.state { return true }
        return false
    }

    private var switchWarning: ServerSetup.SwitchWarning? {
        if case .confirmSwitch(let warning) = setup.state { return warning }
        return nil
    }

    private var switchPresented: Binding<Bool> {
        // Tapping outside cancels; a button's action may run after the dismissal, so the cancel waits
        // a turn and only applies if no button moved the setup on.
        Binding(
            get: { switchWarning != nil },
            set: { shown in
                guard !shown, let warning = switchWarning else { return }
                Task { @MainActor in
                    if setup.state == .confirmSwitch(warning) { setup.edit() }
                }
            })
    }

    private var switchTitle: String { "Switch servers with \(changes(switchWarning?.count ?? 0)) waiting?" }

    private func changes(_ n: Int) -> String { n == 1 ? "1 change" : "\(n) changes" }

    private func connect() {
        focus = nil
        Task { await setup.connect() }
    }
}

/// The brand's bordered text field.
struct FieldStyle: ViewModifier {
    var isInvalid: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
        content
            .font(.qr(.body))
            .foregroundStyle(.qr.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: QuickrMetrics.chipHeight)
            .background(Color.qr.surface, in: shape)
            .overlay(shape.strokeBorder(isInvalid ? Color.qr.danger : .qr.lineStrong, lineWidth: 1))
    }
}
