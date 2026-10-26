import SwiftUI
import WidgetKit

/// The widget extension: the per-topic quick-log widget and the due list (Home Screen and Lock
/// Screen), one Control per topic and one Timer Control per timed topic, and the run's Live
/// Activity.
@main
struct QuickRWidgets: WidgetBundle {
    init() {
        WidgetBootstrap.register()
    }

    var body: some Widget {
        TopicWidget()
        DueListWidget()
        TopicControl()
        TimerControl()
        RunActivityWidget()
    }
}
