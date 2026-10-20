import Foundation
import QuickrCore
import Testing

/// The licences screen lists everything the app ships that isn't ours: every Swift package the
/// app resolves (project.yml's packages, each local package's pins and declared dependencies, and
/// the generated workspace's pins) and every bundled font family, each with its exact licence text.
/// That the built app carries these texts is checked by the app-hosted `LicenceBundleTests`.
@Suite struct LicencesTests {
    /// `<repo>/ios`, from this file's location (QuickrKit/Tests/QuickrCoreTests/Settings/<file>).
    static let ios: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let fonts = ios.appending(path: "QuickrKit/Sources/QuickrUI/Resources/Fonts")
    static let appLicences = ios.appending(path: "Resources/Licences")

    static var listedPackages: Set<String> {
        Set(
            Licence.all.compactMap { licence -> String? in
                if case .package(let identity) = licence.kind { return identity }
                return nil
            })
    }

    struct Resolved: Decodable {
        struct Pin: Decodable { var identity: String }
        var pins: [Pin]
    }

    static func pins(_ url: URL) throws -> Set<String> {
        Set(try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url)).pins.map(\.identity))
    }

    /// SwiftPM's identity for a package URL: its last path component, lowercased, without `.git`.
    static func identity(_ url: String) -> String {
        var name = url.split(separator: "/").last.map(String.init) ?? url
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.lowercased()
    }

    /// project.yml's `packages:`: `(name, path?, url?)`.
    static func projectPackages() throws -> [(name: String, path: String?, url: String?)] {
        let yml = try String(contentsOf: ios.appending(path: "project.yml"), encoding: .utf8)
        var packages: [(name: String, path: String?, url: String?)] = []
        var inPackages = false
        for line in yml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "packages:" {
                inPackages = true
                continue
            }
            guard inPackages else { continue }
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("#") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("  "), !line.hasPrefix("    "), trimmed.hasSuffix(":") {
                packages.append((String(trimmed.dropLast()), nil, nil))
            } else if trimmed.hasPrefix("path:"), !packages.isEmpty {
                packages[packages.count - 1].path = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("url:"), !packages.isEmpty {
                packages[packages.count - 1].url = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            }
        }
        return packages
    }

    @Test func everyPackageTheAppResolvesIsListed() throws {
        let packages = try Self.projectPackages()
        #expect(!packages.isEmpty, "project.yml declares its packages")
        var required = Set<String>()
        for package in packages {
            if let url = package.url { required.insert(Self.identity(url)) }
            guard let path = package.path else {
                #expect(package.url != nil, "\(package.name) has a path or a url")
                continue
            }
            let root = Self.ios.appending(path: path)
            // Its pins, and what its manifest asks for (a dependency added but not resolved yet).
            required.formUnion(try Self.pins(root.appending(path: "Package.resolved")))
            let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
            for match in manifest.matches(of: /\.package\(\s*url:\s*"([^"]+)"/) {
                required.insert(Self.identity(String(match.output.1)))
            }
        }
        // The generated workspace's pins, once `make ios-gen` has made the project.
        let project = Self.ios.appending(path: "quickR.xcodeproj")
        if FileManager.default.fileExists(atPath: project.path) {
            let workspace = project.appending(path: "project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            #expect(FileManager.default.fileExists(atPath: workspace.path), "the generated workspace has its pins")
            if FileManager.default.fileExists(atPath: workspace.path) {
                required.formUnion(try Self.pins(workspace))
            }
        }
        #expect(!required.isEmpty)
        #expect(
            required.subtracting(Self.listedPackages).isEmpty, "unlisted: \(required.subtracting(Self.listedPackages))")
        #expect(Self.listedPackages.subtracting(required).isEmpty, "listed but not shipped")
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

    /// A package's text is exactly its pinned checkout's LICENSE. The checkout is SwiftPM's (the
    /// host build's `.build`, or the app build's `build/spm`); with neither on disk this fails.
    @Test func packageTextsAreTheCheckoutsExactly() throws {
        for licence in Licence.all {
            guard case .package = licence.kind else { continue }
            let checkouts = ["QuickrKit/.build/checkouts", "build/spm/checkouts"].map { Self.ios.appending(path: $0) }
            let directory = licence.url.lastPathComponent
            let upstream = checkouts.map { $0.appending(path: "\(directory)/LICENSE") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let source = try #require(upstream, "no checkout of \(directory) to compare \(licence.file) with")
            let shipped = try String(contentsOf: Self.appLicences.appending(path: licence.file), encoding: .utf8)
            #expect(shipped == (try String(contentsOf: source, encoding: .utf8)), "\(licence.file) is \(source.path)")
        }
    }

    /// A font's text is its vendored OFL file: the family's own (its copyright line names the
    /// project and the URL the screen links to) and the licence's full text.
    @Test func fontTextsAreTheirFamilies() throws {
        for licence in Licence.all {
            guard case .font = licence.kind else { continue }
            let text = try String(contentsOf: Self.fonts.appending(path: licence.file), encoding: .utf8)
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            #expect(first.contains("The \(licence.name) Project Authors"), "\(licence.file): \(first)")
            #expect(first.contains(licence.url.absoluteString), "\(licence.file) links \(licence.url)")
            #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1"), "\(licence.file)")
            #expect(text.contains("THE FONT SOFTWARE IS PROVIDED \"AS IS\""), "\(licence.file) is complete")
        }
    }
}
