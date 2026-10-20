import Foundation
import QuickrCore
import Testing

@testable import QuickR

/// The built app carries every licence text, exactly as the repository has it (which
/// `LicencesTests` holds to the package checkouts and the font families).
@MainActor @Suite struct LicenceBundleTests {
    /// `<repo>/ios`: this file is `ios/AppTests/<file>` (the simulator reads the host's files).
    static let ios: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyLicenceTextIsInTheBuiltAppExactly() throws {
        #expect(Licence.all.count >= 4)
        for licence in Licence.all {
            let source =
                switch licence.kind {
                case .font: Self.ios.appending(path: "QuickrKit/Sources/QuickrUI/Resources/Fonts/\(licence.file)")
                case .package: Self.ios.appending(path: "Resources/Licences/\(licence.file)")
                }
            let bundled = try #require(LicenceTexts.text(licence), "\(licence.file) is in the app")
            #expect(bundled == (try String(contentsOf: source, encoding: .utf8)), "\(licence.file)")
        }
    }
}
