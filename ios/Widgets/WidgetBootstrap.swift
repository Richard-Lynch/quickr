import QuickrData

/// The widget extension's launch path, run in the `WidgetBundle` init: registers its topics for
/// App Intents before WidgetKit asks for a configuration or a timeline, both of which query them.
/// Also compiled into QuickRTests, which runs it on every runtime CI has.
enum WidgetBootstrap {
    static func register() {
        IntentTopicSource.register(PlaceholderTopicRepository())
    }
}
