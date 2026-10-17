import AppIntents
import QuickrData

/// The widget extension's App Intents: the package's types, so `SelectTopicIntent` and
/// `TopicEntity` resolve in this process. No `AppShortcutsProvider` here; that lives in the app.
struct QuickRWidgetIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [QuickrDataIntentsPackage.self] }
}
