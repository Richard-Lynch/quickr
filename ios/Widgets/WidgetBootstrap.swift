import Foundation
import QuickrData

/// The widget extension's launch path, run in the `WidgetBundle` init: registers the active
/// store's topics for App Intents before WidgetKit asks for a configuration or a timeline, both of
/// which query them. Read-only (`ReadOnlyStores`): the widget never migrates, recovers or creates
/// a store; until the app has one, there are no topics. Also compiled into QuickRTests, which runs
/// it on every runtime CI has.
enum WidgetBootstrap {
    static let appGroup = "group.com.bahumia.quickr"

    static func register(location: StoreLocation = .shared(appGroup: appGroup)) {
        IntentTopicSource.register(ActiveStoreTopicRepository(readOnly: ReadOnlyStores(location: location)))
    }
}
