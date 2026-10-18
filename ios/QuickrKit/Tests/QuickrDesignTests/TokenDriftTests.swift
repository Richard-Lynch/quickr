import Foundation
import Testing

/// The colour sets must match the PWA's tokens in `frontend/src/index.css`, light and dark.
@Suite(.timeLimit(.minutes(2))) struct TokenDriftTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
    static let catalog = repo.appending(path: "ios/QuickrKit/Sources/QuickrUI/Resources/Colors.xcassets")

    @Test func colorSetsMatchIndexCSS() throws {
        let css = try String(contentsOf: Self.repo.appending(path: "frontend/src/index.css"), encoding: .utf8)
        let darkStart = try #require(css.range(of: "@media (prefers-color-scheme: dark)"))
        let light = Self.tokens(in: String(css[..<darkStart.lowerBound]))
        let dark = Self.tokens(in: String(css[darkStart.lowerBound...]))
        #expect(light.count == 26)
        #expect(Set(light.keys) == Set(dark.keys))

        let sets = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path())
            .filter { $0.hasSuffix(".colorset") }
            .map { String($0.dropLast(".colorset".count)) }
        #expect(Set(sets) == Set(light.keys))

        for name in light.keys.sorted() {
            let (any, darkHex) = try Self.colorSet(name)
            #expect(any == light[name], "\(name) light")
            #expect(darkHex == dark[name], "\(name) dark")
        }
    }

    /// `--color-name: #rrggbb;` pairs.
    static func tokens(in css: String) -> [String: String] {
        var out: [String: String] = [:]
        for match in css.matches(of: /--color-([a-z0-9-]+):\s*(#[0-9a-f]{6});/) {
            out[String(match.1)] = String(match.2)
        }
        return out
    }

    /// The any-appearance and dark hex values of one colour set.
    static func colorSet(_ name: String) throws -> (String, String) {
        struct ColorSet: Decodable {
            struct Entry: Decodable {
                struct Appearance: Decodable { let value: String }
                struct Color: Decodable { let components: [String: String] }
                let appearances: [Appearance]?
                let color: Color
            }
            let colors: [Entry]
        }
        let data = try Data(contentsOf: catalog.appending(path: "\(name).colorset/Contents.json"))
        let entries = try JSONDecoder().decode(ColorSet.self, from: data).colors
        func hex(_ e: ColorSet.Entry) -> String {
            "#"
                + ["red", "green", "blue"].map { e.color.components[$0, default: ""].dropFirst(2).lowercased() }
                .joined()
        }
        let any = try #require(entries.first { $0.appearances == nil })
        let dark = try #require(entries.first { $0.appearances?.first?.value == "dark" })
        return (hex(any), hex(dark))
    }
}
