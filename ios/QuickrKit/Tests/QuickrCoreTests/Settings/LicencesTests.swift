import Foundation
import QuickrCore
import Testing

/// The licences screen lists everything the app ships that isn't ours: every Swift package in
/// `Package.resolved` and every bundled font family, each with its licence file in the app.
@Suite struct LicencesTests {
    /// `<repo>/ios`, from this file's location.
    static let ios: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // QuickrKit/Tests/QuickrCoreTests/Settings/<file>
        return url
    }()

    static let fonts = ios.appending(path: "QuickrKit/Sources/QuickrUI/Resources/Fonts")
    static let appLicences = ios.appending(path: "Resources/Licences")

    @Test func everyPackageIsListed() throws {
        struct Resolved: Decodable {
            struct Pin: Decodable { var identity: String }
            var pins: [Pin]
        }
        let data = try Data(contentsOf: Self.ios.appending(path: "QuickrKit/Package.resolved"))
        let pins = try JSONDecoder().decode(Resolved.self, from: data).pins.map(\.identity)
        #expect(!pins.isEmpty)
        let listed = Licence.all.compactMap { licence -> String? in
            if case .package(let identity) = licence.kind { return identity }
            return nil
        }
        #expect(Set(listed) == Set(pins), "every pinned package has a licence entry, and only those")
    }

    @Test func everyFontFamilyIsListed() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.fonts.path)
        let families = Set(
            files.filter { $0.hasSuffix(".ttf") || $0.hasSuffix(".otf") }.map { String($0.prefix { $0 != "-" }) })
        #expect(!families.isEmpty)
        let listed = Set(
            Licence.all.compactMap { licence -> String? in
                if case .font(let prefix) = licence.kind { return prefix }
                return nil
            })
        #expect(listed == families, "every bundled font family has a licence entry, and only those")
    }

    /// Each licence's text ships: fonts' next to the fonts (QuickrUI), packages' in the app.
    @Test func everyLicenceFileShips() throws {
        for licence in Licence.all {
            let directory = if case .font = licence.kind { Self.fonts } else { Self.appLicences }
            let text = try String(contentsOf: directory.appending(path: licence.file), encoding: .utf8)
            #expect(text.count > 200, "\(licence.file) holds the licence text")
            switch licence.kind {
            case .font: #expect(text.contains("SIL OPEN FONT LICENSE"), "\(licence.file)")
            case .package: #expect(text.contains("Permission is hereby granted"), "\(licence.file)")
            }
        }
    }

    /// The bundled GRDB licence is the pinned checkout's, when one is on disk.
    @Test func theGRDBLicenceMatchesTheCheckout() throws {
        let checkout = Self.ios.appending(path: "build/spm/checkouts/GRDB.swift/LICENSE")
        guard FileManager.default.fileExists(atPath: checkout.path) else { return }
        let bundled = try String(contentsOf: Self.appLicences.appending(path: "GRDB-LICENSE.txt"), encoding: .utf8)
        #expect(bundled == (try String(contentsOf: checkout, encoding: .utf8)))
    }
}
