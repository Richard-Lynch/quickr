import SwiftUI
import WidgetKit

/// The widget extension. SKEL ships one minimal widget, which proves `TopicEntity` resolves in this
/// process; WIDGETS builds the quick-log and due-list widgets and the Controls (M4).
@main
struct QuickRWidgets: WidgetBundle {
    init() {
        WidgetBootstrap.register()
    }

    var body: some Widget {
        TopicWidget()
    }
}
