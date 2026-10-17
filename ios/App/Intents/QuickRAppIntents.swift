import AppIntents
import QuickrData

/// The app's App Intents: the package's types (`TopicEntity`, `LogEntryIntent`, …) plus the App
/// Shortcuts below. The widget extension declares its own package listing the same one.
struct QuickRAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [QuickrDataIntentsPackage.self] }
}

/// The only `AppShortcutsProvider`, and it must stay in the app target (research/04-siri.md §5:
/// every phrase names the app, at most one entity parameter per phrase, at most 10 shortcuts).
/// `AppEnvironment.start()` refreshes the topic parameters; STORE calls it again after topic changes.
struct QuickRShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogEntryIntent(),
            phrases: [
                "Log \(\.$topic) in \(.applicationName)",
                "Log an entry in \(.applicationName)",
            ],
            shortTitle: "Log Entry",
            systemImageName: "plus.circle"
        )
    }
}
