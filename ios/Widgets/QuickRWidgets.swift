import SwiftUI
import WidgetKit

/// The widget extension: the per-topic quick-log widget and the due list (Home Screen and Lock
/// Screen), and one Control per topic.
@main
struct QuickRWidgets: WidgetBundle {
    init() {
        WidgetBootstrap.register()
    }

    var body: some Widget {
        TopicWidget()
        DueListWidget()
        TopicControl()
    }
}
