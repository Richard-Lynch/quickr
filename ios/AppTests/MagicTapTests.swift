import QuickrUI
import Testing
import UIKit

@testable import QuickR

/// The VoiceOver magic tap (audit X1): the app's `UIApplication` is ``QuickrApplication``
/// (installed at launch), knows the app's toasts, runs the newest toast's action, and
/// declines (so the system's own magic tap runs) when no toast has one. VoiceOver's routing to it
/// up the responder chain is checked on a device (VoiceOver doesn't run in the simulator).
@MainActor
@Suite struct MagicTapTests {
    @Test func theAppIsAQuickrApplicationWiredToTheToasts() throws {
        _ = try #require(QuickrApplication.current, "QuickRApp.init installs it")
        #expect(QuickrApplication.toasts != nil, "with the environment's toasts")
    }

    @Test func itRunsTheNewestUndoAndDeclinesWithoutOne() throws {
        let app = try #require(QuickrApplication.current)
        let saved = try #require(QuickrApplication.toasts)
        defer { QuickrApplication.install(toasts: saved) }
        let center = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        QuickrApplication.install(toasts: center)
        #expect(!app.accessibilityPerformMagicTap(), "no toast: the system's magic tap runs")
        var undone = 0
        center.show(Toast("Logged", action: .init("Undo") { undone += 1 }))
        center.show(Toast("Copied"))
        #expect(app.accessibilityPerformMagicTap())
        #expect(undone == 1)
        #expect(!app.accessibilityPerformMagicTap())
    }
}
