import QuickrUI
import Testing
import UIKit

@testable import QuickR

/// The VoiceOver magic tap (audit X1): the app delegate, the end of the responder chain, runs the
/// newest toast's action, and declines (so the system's own magic tap runs) when no toast has one.
/// The gesture's route to it is checked on a device (VoiceOver doesn't run in the simulator).
@MainActor
@Suite struct MagicTapTests {
    @Test func launchHandsTheDelegateTheAppsToasts() {
        #expect(AppDelegate.toasts != nil, "QuickRApp.init")
    }

    @Test func itRunsTheNewestUndoAndDeclinesWithoutOne() {
        let saved = AppDelegate.toasts
        defer { AppDelegate.toasts = saved }
        let center = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        AppDelegate.toasts = center
        let delegate = AppDelegate()
        #expect(!delegate.accessibilityPerformMagicTap(), "no toast: the system's magic tap runs")
        var undone = 0
        center.show(Toast("Logged", action: .init("Undo") { undone += 1 }))
        center.show(Toast("Copied"))
        #expect(delegate.accessibilityPerformMagicTap())
        #expect(undone == 1)
        #expect(!delegate.accessibilityPerformMagicTap())
    }
}
