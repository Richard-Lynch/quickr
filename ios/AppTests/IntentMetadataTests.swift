import Foundation
import Testing

/// The App Intents metadata Xcode generated for the installed app and widget extension (PLAN M1
/// platform proof). Both bundles must carry the package's types, with exactly one package include
/// each, and only the app may carry the App Shortcuts. This runs on every runtime, including iOS
/// 26.0, where AppIntentsTesting (`QuickRUITests/IntentResolutionTests`) is unavailable.
@Suite struct IntentMetadataTests {
    struct Metadata {
        let actions: Set<String>
        let entities: Set<String>
        let queries: Set<String>
        let shortcuts: [String]
        let includes: [String]

        init(bundle: URL) throws {
            let dir = bundle.appendingPathComponent("Metadata.appintents")
            let actionsData = try Data(contentsOf: dir.appendingPathComponent("extract.actionsdata"))
            let json = try #require(try JSONSerialization.jsonObject(with: actionsData) as? [String: Any])
            func keys(_ name: String) -> Set<String> {
                Set((json[name] as? [String: Any]).map { Array($0.keys) } ?? [])
            }
            actions = keys("actions")
            entities = keys("entities")
            queries = keys("queries")
            shortcuts = (json["autoShortcuts"] as? [[String: Any]] ?? []).compactMap {
                $0["actionIdentifier"] as? String
            }
            let packageData = try Data(contentsOf: dir.appendingPathComponent("extract.packagedata"))
            let package = try #require(try JSONSerialization.jsonObject(with: packageData) as? [String: Any])
            includes = package["includes"] as? [String] ?? []
        }
    }

    static var appURL: URL { Bundle.main.bundleURL }
    static var widgetsURL: URL { Bundle.main.builtInPlugInsURL!.appendingPathComponent("QuickRWidgets.appex") }

    @Test(arguments: ["app", "widgets"])
    func bundleCarriesThePackageIntentsOnce(_ name: String) throws {
        let metadata = try Metadata(bundle: name == "app" ? Self.appURL : Self.widgetsURL)
        #expect(metadata.entities == ["TopicEntity"])
        #expect(metadata.queries == ["TopicEntityQuery"])
        #expect(metadata.actions.isSuperset(of: ["LogEntryIntent", "SelectTopicIntent"]))
        #expect(metadata.includes.count == 1)
        #expect(metadata.includes.first?.contains("QuickrData") == true)
    }

    @Test func onlyTheAppHasAppShortcuts() throws {
        #expect(try Metadata(bundle: Self.appURL).shortcuts == ["LogEntryIntent"])
        #expect(try Metadata(bundle: Self.widgetsURL).shortcuts.isEmpty)
    }
}
