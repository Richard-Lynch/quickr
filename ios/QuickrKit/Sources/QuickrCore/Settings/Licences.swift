import Foundation

/// Settings ▸ About ▸ Licences: what the app ships that isn't ours, and the licence text each
/// comes with. A host test keeps the list in step with the Swift packages (`Package.resolved`) and
/// the bundled fonts, so a new dependency can't ship unlisted.
public struct Licence: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A Swift package (its identity in `Package.resolved`).
        case package(identity: String)
        /// A font family bundled in QuickrUI (its files' name prefix).
        case font(prefix: String)
    }

    public var name: String
    public var kind: Kind
    /// "MIT", "SIL Open Font License 1.1".
    public var licence: String
    public var url: URL
    /// The licence file: a font's next to it in QuickrUI, a package's in the app (`ios/Resources/Licences`).
    public var file: String

    public var id: String { name }

    public static let all: [Licence] = [
        Licence(
            name: "GRDB.swift", kind: .package(identity: "grdb.swift"), licence: "MIT",
            url: URL(string: "https://github.com/groue/GRDB.swift")!, file: "GRDB-LICENSE.txt"),
        Licence(
            name: "Bricolage Grotesque", kind: .font(prefix: "BricolageGrotesque"),
            licence: "SIL Open Font License 1.1",
            url: URL(string: "https://github.com/ateliertriay/bricolage")!, file: "BricolageGrotesque-OFL.txt"),
        Licence(
            name: "Instrument Sans", kind: .font(prefix: "InstrumentSans"), licence: "SIL Open Font License 1.1",
            url: URL(string: "https://github.com/Instrument/instrument-sans")!, file: "InstrumentSans-OFL.txt"),
        Licence(
            name: "JetBrains Mono", kind: .font(prefix: "JetBrainsMono"), licence: "SIL Open Font License 1.1",
            url: URL(string: "https://github.com/JetBrains/JetBrainsMono")!, file: "JetBrainsMono-OFL.txt"),
    ]
}
