import Foundation
import QuickrData

/// The widget extension's launch path, run in the `WidgetBundle` init: registers the active
/// store's topics for App Intents (read-only: the widget never writes them) before WidgetKit asks
/// for a configuration or a timeline, both of which query them. Also compiled into QuickRTests,
/// which runs it on every runtime CI has.
enum WidgetBootstrap {
    static let appGroup = "group.com.bahumia.quickr"

    static func register(location: StoreLocation = .shared(appGroup: appGroup)) {
        do {
            let partitions = try StorePartitions.open(at: location)
            IntentTopicSource.register(ActiveStoreTopicRepository(partitions: partitions))
        } catch {
            IntentTopicSource.register(NoTopicRepository())  // the next timeline request retries
        }
    }
}
