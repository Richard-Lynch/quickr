#if canImport(AppIntentsTesting)
import AppIntentsTesting
import XCTest

/// SPIKE (INTENTS): measurements for research/04-siri.md, not regression tests. Opt-in
/// (`TEST_RUNNER_QUICKR_INTENT_SPIKE=1`); results go to the console and attachments.
final class IntentSpikeTests: XCTestCase {
    static let app = "com.bahumia.quickr"

    override func setUp() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("AppIntentsTesting needs an iOS 27 runtime") }
        guard ProcessInfo.processInfo.environment["QUICKR_INTENT_SPIKE"] == "1" else {
            throw XCTSkip("spike: set TEST_RUNNER_QUICKR_INTENT_SPIKE=1")
        }
        continueAfterFailure = true
        await MainActor.run { XCUIApplication().launch() }
    }

    private func note(_ text: String) {
        print("SPIKE-RESULT \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "spike"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The processing budget: an intent that works 10, 35 and 65 s without prompting.
    func testProcessingBudget() async throws {
        guard #available(iOS 27.0, *) else { return }
        let definitions = IntentDefinitions(bundleIdentifier: Self.app)
        for seconds in [10, 35, 65] {
            let started = Date()
            do {
                let result = try await definitions.intents["SpikeWorkIntent"].makeIntent(seconds: seconds).run()
                let value: String = try result.value
                note("work \(seconds) s: ok after \(Date().timeIntervalSince(started)) s: \(value)")
            } catch {
                note("work \(seconds) s: error after \(Date().timeIntervalSince(started)) s: \(error)")
            }
        }
    }

    /// What AppIntentsTesting does with an intent that prompts (it has no way to answer).
    func testPromptingUnderAppIntentsTesting() async throws {
        guard #available(iOS 27.0, *) else { return }
        let started = Date()
        do {
            let result = try await IntentDefinitions(bundleIdentifier: Self.app).intents["SpikePromptIntent"]
                .makeIntent().run()
            note("prompts under AppIntentsTesting: returned after \(Date().timeIntervalSince(started)) s: \(result)")
        } catch {
            note("prompts under AppIntentsTesting: error after \(Date().timeIntervalSince(started)) s: \(error)")
        }
    }

    @MainActor
    private func attachTree(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        note("\(name) tree:\n\(app.debugDescription.prefix(6000))")
    }

    /// Repeated `requestValue` on one parameter, and user waits vs the 30 s budget: runs
    /// `SpikePromptIntent` from the Shortcuts app (which answers prompts on the simulator) and
    /// answers 1, then (after 40 s) 2, then 3.
    @MainActor
    func testPromptsInShortcuts() throws {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        sleep(3)
        if shortcuts.buttons["BackButton"].exists { shortcuts.buttons["BackButton"].tap() }
        sleep(2)
        attachTree(shortcuts, "library")
        let app = shortcuts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'quickR'")).firstMatch
        guard app.waitForExistence(timeout: 10) else {
            note("no quickR entry in the library")
            return
        }
        app.tap()
        sleep(2)
        attachTree(shortcuts, "quickr-shortcuts")
        let tile = shortcuts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Spike Prompts'")).firstMatch
        guard tile.waitForExistence(timeout: 10) else {
            note("no Spike Prompts tile")
            return
        }
        tile.tap()
        let started = Date()
        sleep(5)
        attachTree(shortcuts, "after-tap")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        attachTree(springboard, "springboard-after-tap")
        for (round, value, wait) in [(1, "1", UInt32(0)), (2, "2", UInt32(40)), (3, "3", UInt32(0))] {
            // The prompt's field: in the Shortcuts app or over it (SpringBoard), never the search field.
            let inApp = shortcuts.textFields.firstMatch
            let overApp = springboard.textFields.firstMatch
            var field = inApp
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if inApp.exists { field = inApp; break }
                if overApp.exists { field = overApp; break }
                usleep(250_000)
            }
            guard field.exists else {
                attachTree(shortcuts, "prompt-\(round)-missing")
                note("prompt \(round): no field after \(Date().timeIntervalSince(started)) s")
                return
            }
            if round == 1 { attachTree(shortcuts, "prompt-1") }
            sleep(wait)
            field.tap()
            field.typeText(value)
            for host in [shortcuts, springboard] {
                if let button = ["Done", "OK", "Continue", "Submit"].lazy.map({ host.buttons[$0] }).first(where: \.exists) {
                    button.tap()
                    break
                }
            }
            note("prompt \(round): answered \(value) at \(Date().timeIntervalSince(started)) s")
            sleep(2)
        }
        let result = shortcuts.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'SPIKE'")).firstMatch
        if result.waitForExistence(timeout: 20) {
            note("result: \(result.label) at \(Date().timeIntervalSince(started)) s")
        } else {
            note("no result after \(Date().timeIntervalSince(started)) s")
        }
        attachTree(shortcuts, "after")
    }

    /// Exploration: the Shortcuts app's UI, to find quickR's App Shortcuts.
    @MainActor
    func testShortcutsAppExploration() throws {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        sleep(3)
        for _ in 0..<3 {
            for label in ["Continue", "Not Now", "OK", "Allow"] where shortcuts.buttons[label].exists {
                shortcuts.buttons[label].tap()
                sleep(1)
            }
        }
        let shot = XCTAttachment(screenshot: shortcuts.screenshot())
        shot.name = "shortcuts-home"
        shot.lifetime = .keepAlways
        add(shot)
        note("shortcuts tree:\n\(shortcuts.debugDescription.prefix(8000))")
    }
}
#endif
