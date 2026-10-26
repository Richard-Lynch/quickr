import AppIntents
import Foundation
import Testing

@testable import QuickR

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
                // The Live Activity's buttons: drawn by the widget, run in the app's process (timers.md §10.3).
                "RunActivityButtonIntent",
                // Timed topics' widget buttons and Control, the Action button and Siri (§11.3).
                "RunWidgetIntent", "AdvanceRunIntent", "RunActionIntent",
            ]))
        #expect(!metadata.hasPackageData)
    }

    @Test func onlyTheAppHasAppShortcuts() throws {
        // One parameterised timer shortcut for every run action (timers.md §11.3).
        var shortcuts = [
            "LogTopicIntent", "RepeatLastEntryIntent", "OpenRecordIntent", "WhatsDueIntent", "RunActionIntent",
        ]
        #if DEBUG
        shortcuts.append("SpikePromptIntent")  // the DEBUG-only prompt harness (research/04-siri.md)
        #endif
        let app = try Metadata(bundle: Self.appURL).shortcuts
        #expect(app == shortcuts)
        #expect(try Metadata(bundle: Self.widgetsURL).shortcuts.isEmpty)
    }

    /// iOS allows an app at most 10 App Shortcuts (research/04-siri.md §5): past that it drops
    /// them. The DEBUG build's spike counts too.
    @Test func theAppHasAtMostTenAppShortcuts() throws {
        let count = try Metadata(bundle: Self.appURL).shortcuts.count
        #expect(count <= 10)
        #expect(QuickRShortcuts.appShortcuts.count == count)
    }
}
