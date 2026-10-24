import XCTest

/// I-MANAGE against the fake server (`-QuickrUITest`, https://quickr.test): R10 (timers.md §13.3),
/// Edit times on a finished run and the Overview's new median (`-QuickrSeedTimedTopic`: Morning,
/// one run of Shower 4:00 then Dress 5:00), and publishing a timed topic from the builder.
final class TimingUITests: XCTestCase {
    static let entryId = "00000000-0000-4000-8000-0000000000e3"

    override func setUp() {
        continueAfterFailure = false
    }

    /// R10: the stats show the run's 9:00; Dress ends two minutes earlier in Edit times; the
    /// entry shows 7:00 and so does the Overview's median.
    @MainActor
    func testEditTimesThenTheStatsShowTheNewMedian() throws {
        let app = launch(open: "quickr://t/morning", extra: ["-QuickrSeedTimedTopic"])
        let median = element("overview.timing.median", in: app)
        XCTAssertTrue(median.waitForExistence(timeout: 20))
        XCTAssertEqual(median.label, "9:00, median")
        XCTAssertTrue(element("overview.timing.step.dress", in: app).exists, "per-step bars")

        // In the app (a link would relaunch it, with a fresh store and fake server).
        selectTopicTab("Entries", in: app)
        let row = element("entry.\(Self.entryId)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let total = element("edit.timing.total", in: app)
        XCTAssertTrue(total.waitForExistence(timeout: 15))
        XCTAssertEqual(total.label, "9:00")
        XCTAssertFalse(element("edit.capturedAt", in: app).exists, "a timed entry's time is its run's")
        tap("edit.timing.edit", in: app)

        let end = app.textFields["timing.segment1.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        let shown = end.value as? String ?? ""
        let earlier = try XCTUnwrap(Self.shifted(shown, by: -120), "the field shows a local time: \(shown)")
        // The caret at the end, then the text replaced.
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        end.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown.count))
        end.typeText(earlier)
        XCTAssertEqual(end.value as? String, earlier)
        XCTAssertEqual(element("timing.total", in: app).label, "Total, 7:00", "the total follows as you type")
        snap(app, "edit-times")
        app.buttons["timing.save"].tap()

        XCTAssertTrue(toast("Times updated", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["timing.save"].exists, "the sheet closes")
        XCTAssertEqual(element("edit.timing.total", in: app).label, "7:00")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        selectTopicTab("Overview", in: app)
        let after = element("overview.timing.median", in: app)
        XCTAssertTrue(after.waitForExistence(timeout: 20))
        let updated = NSPredicate(format: "label == '7:00, median'")
        expectation(for: updated, evaluatedWith: after)
        waitForExpectations(timeout: 15)
    }

    /// The Timed switch and a step, on an untimed topic: a timer-only change is reviewed ("No
    /// question changes.") and published as v2.
    @MainActor
    func testPublishingATimedTopic() {
        let app = launch(open: "quickr://t/mood/edit")
        XCTAssertTrue(element("editQuestions.q0.header", in: app).waitForExistence(timeout: 15))
        let timed = app.switches["editQuestions.timed"]
        scrollTo(timed, in: app)
        XCTAssertTrue(timed.waitForExistence(timeout: 5))
        // The switch itself, at the row's trailing edge.
        timed.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(timed.value as? String, "1")
        tap("editQuestions.addStep", in: app)
        let label = app.textFields["editQuestions.step0.label"]
        scrollTo(label, in: app)
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
        label.typeText("Shower")
        dismissKeyboard(app)
        let key = element("editQuestions.step0.key", in: app)
        XCTAssertTrue(key.label.contains("shower"), "a new step's key follows its label: \(key.label)")
        tap("editQuestions.review", in: app)

        let headline = element("review.headline", in: app)
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertTrue(headline.label.contains("Ready to publish as v2"), headline.label)
        XCTAssertEqual(element("review.noChanges", in: app).label, "No question changes.")
        XCTAssertTrue(app.staticTexts["Timed, with 1 step"].exists)
        snap(app, "builder-review-timer")
        app.buttons["review.publish"].tap()
        XCTAssertTrue(toast("Published v2", in: app).waitForExistence(timeout: 10))
        let v2 = element("versions.v2", in: app)
        XCTAssertTrue(v2.waitForExistence(timeout: 15))
    }

    // MARK: Helpers

    /// A field's local time (`2026-10-23 07:09:00`) moved by `seconds`, in the same form.
    static func shifted(_ text: String, by seconds: TimeInterval) -> String? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.date(from: text).map { format.string(from: $0.addingTimeInterval(seconds)) }
    }

    @MainActor
    private func launch(open url: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", url] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func toast(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toast.text")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func tap(_ id: String, in app: XCUIApplication) {
        let target = element(id, in: app)
        scrollTo(target, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), id)
        target.tap()
    }

    /// Drags until `element` exists and is hittable (bounded).
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        // Whole on screen: a row half under the home indicator is hittable, but a tap at its centre
        // misses it.
        for _ in 0..<12 where !(element.exists && element.isHittable && app.frame.contains(element.frame)) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        }
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.navigationBars.firstMatch.tap()
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
