import Foundation
import OSLog
import QuickrData
import QuickrUI
import Synchronization
import WidgetKit

/// The widget extension's launch path, run in the `WidgetBundle` init: registers the active
/// store's topics for App Intents before WidgetKit asks for a configuration or a timeline, both of
/// which query them, the intents' write context (`WidgetWrites`), and the design system's fonts. Read-only (`ReadOnlyStores`): the widget never
/// migrates, recovers or creates a store; until the app has one, there are no topics. Also compiled
/// into QuickRTests, which runs it on every runtime CI has.
enum WidgetBootstrap {
    static let appGroup = "group.com.bahumia.quickr"
    static let log = Logger(subsystem: "com.bahumia.quickr.widgets", category: "timeline")

    /// Where the timelines read from (`register(location:)` sets it; tests pass their own).
    private static let location = Mutex(StoreLocation.shared(appGroup: appGroup))

    static func register(location: StoreLocation = .shared(appGroup: appGroup)) {
        self.location.withLock { $0 = location }
        _ = QuickrFonts.register()
        IntentTopicSource.register(ActiveStoreTopicRepository(readOnly: ReadOnlyStores(location: location)))
        // A chip, ✓ or Control logs through INTENTS' one commit into the writable active store,
        // then flushes within the extension's budget; the widgets show "queued" meanwhile.
        IntentWrites.register(
            WidgetWrites.context(location: location, reload: { WidgetCenter.shared.reloadAllTimelines() }))
    }

    /// The active store's widget reads, or nil before the app has a store (or while it can't be
    /// opened read-only).
    static func reader() -> WidgetReader? {
        let location = location.withLock { $0 }
        do {
            guard let store = try ReadOnlyStores(location: location).activeStore() else { return nil }
            return WidgetReader(store: store)
        } catch {
            log.error("no store for the widgets: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
