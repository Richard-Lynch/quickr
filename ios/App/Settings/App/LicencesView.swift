import QuickrCore
import QuickrUI
import SwiftUI

/// Settings ▸ About ▸ Licences: everything the app ships that isn't ours (`Licence.all`), each with
/// its licence text.
struct LicencesView: View {
    var body: some View {
        List(Licence.all) { licence in
            NavigationLink {
                LicenceText(licence: licence)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(licence.name).font(.qr(.label))
                    Text(licence.licence).font(.qr(.caption)).foregroundStyle(.qr.muted)
                }
            }
            .accessibilityIdentifier("licence.\(licence.name)")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .qrPaperBackground()
        .navigationTitle("Licences")
        .accessibilityIdentifier("licences.list")
    }
}

/// One licence: where the project lives and the full text.
private struct LicenceText: View {
    let licence: Licence

    private var text: String {
        let loaded: String? =
            switch licence.kind {
            case .font: QuickrFonts.licenceText(licence.file)
            case .package:
                Bundle.main.url(forResource: licence.file, withExtension: nil)
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }
        return loaded ?? "The licence text is missing from this build."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Link(licence.url.absoluteString, destination: licence.url).font(.qr(.callout))
                Text(text)
                    .font(.qr(.monoCaption))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("licence.text")
            }
            .padding(16)
        }
        .qrPaperBackground()
        .navigationTitle(licence.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
