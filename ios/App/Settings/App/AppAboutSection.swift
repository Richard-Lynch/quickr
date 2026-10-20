import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// Settings ▸ About: the app's version, the server and this iPhone's copy of it, and the licences.
struct AppAboutSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
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
            NavigationLink("Licences") { LicencesView() }
                .accessibilityIdentifier("settings.licences")
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
