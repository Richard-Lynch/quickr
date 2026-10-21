import Foundation
import Testing

/// The App Intents metadata Xcode generated for the installed app and widget extension (PLAN M1
/// platform proof). Both bundles must carry the package's types, neither may declare an
/// `AppIntentsPackage` include (iOS 26.0's linkd rejects one for a static library and drops every
/// intent; see `QuickrDataIntents.swift`), and only the app may carry the App Shortcuts. This runs on every runtime, including iOS
/// 26.0, where AppIntentsTesting (`QuickRUITests/IntentResolutionTests`) is unavailable.
@Suite struct IntentMetadataTests {
    struct Metadata {
        let actions: Set<String>
        let entities: Set<String>
        let queries: Set<String>
        let shortcuts: [String]
        let hasPackageData: Bool

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
            let packageData = dir.appendingPathComponent("extract.packagedata")
            hasPackageData = FileManager.default.fileExists(atPath: packageData.path)
        }
    }

    static var appURL: URL { Bundle.main.bundleURL }
    static var widgetsURL: URL { Bundle.main.builtInPlugInsURL!.appendingPathComponent("QuickRWidgets.appex") }

    @Test(arguments: ["app", "widgets"])
    func bundleCarriesThePackageIntentsWithoutAPackageInclude(_ name: String) throws {
        let metadata = try Metadata(bundle: name == "app" ? Self.appURL : Self.widgetsURL)
        #expect(metadata.entities == ["TopicEntity", "QuestionOptionEntity"])
        #expect(metadata.queries == ["TopicEntityQuery", "QuestionOptionQuery"])
        #expect(
            metadata.actions.isSuperset(of: [
                "LogEntryIntent", "SelectTopicIntent", "RepeatLastEntryIntent", "OpenRecordIntent", "WhatsDueIntent",
            ]))
        #expect(!metadata.hasPackageData)
    }

    @Test func onlyTheAppHasAppShortcuts() throws {
        var shortcuts = ["LogTopicIntent", "RepeatLastEntryIntent", "OpenRecordIntent", "WhatsDueIntent"]
        #if DEBUG
        shortcuts.append("SpikePromptIntent")  // the DEBUG-only prompt harness (research/04-siri.md)
        #endif
        #expect(try Metadata(bundle: Self.appURL).shortcuts == shortcuts)
        #expect(try Metadata(bundle: Self.widgetsURL).shortcuts.isEmpty)
    }
}
