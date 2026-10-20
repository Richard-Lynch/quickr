import SwiftUI
import WidgetKit

/// The widget extension: the per-topic quick-log widget and the due list, on the Home Screen and
/// the Lock Screen (the Controls come with INTENTS).
@main
struct QuickRWidgets: WidgetBundle {
    init() {
        WidgetBootstrap.register()
    }

    var body: some Widget {
        TopicWidget()
        DueListWidget()
    }
}
