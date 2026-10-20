import XCTest

/// The main flows end to end: the app on the simulator against this worktree's integration stack
/// (a real backend behind the fault proxy), checked on the server, not only on screen.
///
/// `make ios-uitest-e2e` starts the stack and passes its URLs to the test runner (as
/// `TEST_RUNNER_QUICKR_IT_*`). Without them these tests skip, so the UI plan runs anywhere; with
/// `QUICKR_IT_REQUIRED=1` they fail instead.
@MainActor
final class EndToEndUITests: XCTestCase {
    private var stack: Stack!

    override func setUp() async throws {
        continueAfterFailure = false
        stack = try Stack.fromEnvironment()
        try await stack.resetProxy()
        try await stack.removeAllTopics()
    }

    /// Design loop row a, online: one tap on a chip logs, the server has the entry, and Undo
    /// removes it there too.
    func testAChipLogReachesTheServerAndUndoRemovesIt() async throws {
        let topic = try await stack.createTopic(
            "Mood", questions: [Stack.choice("mood", "Mood", ["good": "Good", "meh": "Meh"])])
        let app = launch()
        let tile = try tile(app, topic.slug)
        let chip = tile.buttons["chip.good"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        snap(app, "e2e-chip-1-home")
        chip.tap()

        let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.hasPrefix("Logged Good"), toast.label)
        XCTAssertFalse(toast.label.contains("saved on this device"), "online, it is sent: \(toast.label)")
        snap(app, "e2e-chip-2-logged")
        snapBoth(app, "uit2-home-logged")
        let entries = try await stack.eventually("the entry on the server") {
            let entries = try await self.stack.entries(topic)
            return entries.count == 1 ? entries : nil
        }
        XCTAssertEqual(Stack.answer(entries[0], "mood") as? String, "good")

        app.buttons["toast.action"].tap()
        XCTAssertTrue(toast.waitForLabel(prefix: "Undone"))
        snap(app, "e2e-chip-3-undone")
        _ = try await stack.eventually("Undo deletes it on the server") {
            try await self.stack.entries(topic).isEmpty ? true : nil
        }
    }

    /// Design loop row g: offline, the record screen saves on the device; back online, the entry
    /// syncs when the app comes back to the foreground.
    func testAnEntryRecordedOfflineSyncsOnReconnect() async throws {
        let topic = try await stack.createTopic("Water", questions: [Stack.int("glasses", "Glasses", max: 20)])
        let app = launch()
        _ = try tile(app, topic.slug)  // the first sync has the topic

        try await stack.goOffline()
        app.buttons["Log \(topic.name)"].firstMatch.tap()
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 15))
        glasses.replaceText("3")  // it starts at 0, like its tile
        snap(app, "e2e-offline-1-record")
        app.buttons["record.save"].tap()

        let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
        XCTAssertTrue(toast.waitForLabel(prefix: "Saved on this device", timeout: 15))
        snap(app, "e2e-offline-2-saved")
        snapBoth(app, "uit2-offline-saved")
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 10))
        let entriesOffline = try await stack.entries(topic)
        XCTAssertTrue(entriesOffline.isEmpty, "nothing reached the server")

        try await stack.goOnline()
        XCUIDevice.shared.press(.home)
        app.activate()
        let entries = try await stack.eventually("the entry syncs on reconnect", timeout: 30) {
            let entries = try await self.stack.entries(topic)
            return entries.isEmpty ? nil : entries
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Stack.answer(entries[0], "glasses") as? Int, 3)
        XCTAssertEqual(entries[0]["source"] as? String, "ios")
        snap(app, "e2e-offline-3-synced")
    }

    /// Links name a topic by slug or by id. Cold (at launch) and warm (while running), a
    /// `quickr://` link and the server's own PWA URL open the same record screen.
    func testLinksOpenTheRecordScreenBySlugOrId() async throws {
        let topic = try await stack.createTopic("Steps", questions: [Stack.int("steps", "Steps", max: 100_000)])

        let app = launch(open: "quickr://t/\(topic.slug)/record")
        XCTAssertTrue(app.textFields["form.field.steps"].waitForExistence(timeout: 20), "cold quickr:// by slug")
        XCTAssertTrue(app.navigationBars[topic.name].exists)

        for link in [
            "quickr://t/\(topic.id)/record",  // by id, as the sync sheet's fix links do
            "\(stack.baseURL)/t/\(topic.slug)/record",  // the PWA's URL for the same screen
        ] {
            app.terminate()
            let warm = launch()
            _ = try tile(warm, topic.slug)
            warm.open(URL(string: link)!)
            XCTAssertTrue(warm.textFields["form.field.steps"].waitForExistence(timeout: 15), "warm \(link)")
            XCTAssertTrue(warm.navigationBars[topic.name].exists, link)
        }
    }

    /// "Same as last time" offers the latest entry the server has, even one logged elsewhere.
    func testSameAsLastOffersTheEntryLoggedOnTheWeb() async throws {
        let topic = try await stack.createTopic(
            "Sleep",
            questions: [
                Stack.int("hours", "Hours", max: 24),
                Stack.choice("quality", "Quality", ["poor": "Poor", "ok": "OK", "great": "Great"]),
            ])
        try await stack.createEntry(topic, answers: ["hours": 7, "quality": "great"])

        let app = launch(open: "quickr://t/\(topic.slug)/record")
        let same = app.buttons["form.sameAsLast"]
        XCTAssertTrue(same.waitForExistence(timeout: 20))
        snap(app, "e2e-same-1-offered")
        same.tap()
        XCTAssertTrue((app.textFields["form.field.hours"].value as? String ?? "").hasPrefix("7"))
        snap(app, "e2e-same-2-applied")
        snapBoth(app, "uit2-same-as-last")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.staticTexts["Logged \(topic.name)"].waitForExistence(timeout: 15))

        let entries = try await stack.eventually("both entries on the server") {
            let entries = try await self.stack.entries(topic)
            return entries.count == 2 ? entries : nil
        }
        for entry in entries {
            XCTAssertEqual(Stack.answer(entry, "hours") as? Int, 7)
            XCTAssertEqual(Stack.answer(entry, "quality") as? String, "great")
        }
    }

    // MARK: - Helpers

    private func launch(open url: String? = nil) -> XCUIApplication { stack.launch(open: url) }

    /// The topic's tile, once the list has synced it; scrolled into view.
    private func tile(_ app: XCUIApplication, _ slug: String) throws -> XCUIElement {
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 20), "the home screen")
        let element = app.descendants(matching: .any)["tile.\(slug)"]
        XCTAssertTrue(element.waitForExistence(timeout: 20), "tile.\(slug) after the first sync")
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        return element
    }

    /// A screenshot kept with the results (the demo GIFs are made from them).
    private func snap(_ app: XCUIApplication, _ name: String) {
        usleep(700_000)  // let the animations settle
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// `<name>-light` and `<name>-dark` for docs/ios/demo/m2 (then back to light).
    private func snapBoth(_ app: XCUIApplication, _ name: String) {
        for (appearance, suffix) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            usleep(800_000)
            snap(app, "\(name)-\(suffix)")
        }
        XCUIDevice.shared.appearance = .light
    }
}
