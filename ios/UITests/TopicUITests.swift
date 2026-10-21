import XCTest

/// TOPIC against the fake server (`-QuickrUITest`, https://quickr.test): topic settings (details,
/// schedule, archive with Undo, delete after typing the slug), creating a topic, the online-only
/// message, and the settings screen at the largest accessibility size.
final class TopicUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsSaveDetailsAndScheduleArchiveUndoAndDelete() {
        let app = launch(open: "quickr://t/mood/settings")
        let description = field("topicSettings.description", in: app)
        XCTAssertTrue(description.waitForExistence(timeout: 15))

        // Details: only the description changed.
        description.tap()
        description.typeText("How the day felt")
        dismissKeyboard(app)
        tap("topicSettings.saveDetails", in: app)
        XCTAssertTrue(toast("Saved", in: app).waitForExistence(timeout: 10))

        // Schedule: Daily at 08:00, every day.
        app.buttons["Daily"].firstMatch.tap()
        let preview = app.staticTexts["topicSettings.schedule.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.label, "Daily 08:00")
        tap("topicSettings.saveSchedule", in: app)
        XCTAssertTrue(toast("Schedule saved", in: app).waitForExistence(timeout: 10))

        // Archive, then Undo.
        tap("topicSettings.archive", in: app)
        XCTAssertTrue(toast("Topic archived", in: app).waitForExistence(timeout: 10))
        app.buttons["toast.action"].firstMatch.tap()
        XCTAssertTrue(toast("Topic unarchived", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("topicSettings.archive", in: app).waitForExistence(timeout: 10))

        // Archive again, then delete: the button waits for the typed slug.
        tap("topicSettings.archive", in: app)
        XCTAssertTrue(toast("Topic archived", in: app).waitForExistence(timeout: 10))
        tap("topicSettings.delete", in: app)
        let confirmation = app.textFields["deleteTopic.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        let confirm = app.buttons["deleteTopic.confirm"]
        XCTAssertFalse(confirm.isEnabled)
        snap(app, "topic-delete")
        confirmation.typeText("mood")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        // Gone: back on the topic list, without Mood.
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        XCTAssertTrue(toast("Topic deleted", in: app).waitForExistence(timeout: 10))
    }

    /// Codex r1: a slug save moves the screen to the new link; an unsaved schedule edit survives.
    @MainActor
    func testANewSlugKeepsAnUnsavedSchedule() {
        let app = launch(open: "quickr://t/workout/settings")
        let slug = app.textFields["topicSettings.slug"]
        XCTAssertTrue(slug.waitForExistence(timeout: 15))
        app.buttons["Daily"].firstMatch.tap()  // unsaved
        slug.tap()
        slug.typeText("-plan")
        dismissKeyboard(app)
        tap("topicSettings.saveDetails", in: app)
        XCTAssertTrue(toast("Saved", in: app).waitForExistence(timeout: 10))

        XCTAssertEqual(app.textFields["topicSettings.slug"].value as? String, "workout-plan")
        let preview = app.staticTexts["topicSettings.schedule.preview"]
        scrollTo(preview, in: app)
        XCTAssertEqual(preview.label, "Daily 08:00", "the schedule draft is still there")
        XCTAssertTrue(element("topicSettings.saveSchedule", in: app).isEnabled, "and still unsaved")
    }

    @MainActor
    func testCreateATopicOpensItsRecordScreen() {
        let app = launch(open: "quickr://new")
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        name.typeText("Water")
        XCTAssertEqual(app.textFields["newTopic.slug"].value as? String, "water", "the slug follows the name")
        let label = app.textFields["newTopic.q0.label"]
        label.tap()
        label.typeText("Glasses\n")  // Return closes the keyboard
        snap(app, "topic-new")
        tap("newTopic.create", in: app)

        let created = toast("Topic created", in: app).waitForExistence(timeout: 10)
        let banner = element("newTopic.banner", in: app)
        XCTAssertTrue(created, banner.exists ? "banner: \(banner.label)" : "no toast, no banner")
        XCTAssertTrue(app.navigationBars["Water"].waitForExistence(timeout: 15), "its record screen")
        XCTAssertTrue(field("form.field.glasses", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testAnInvalidNewTopicShowsItsErrors() {
        let app = launch(open: "quickr://new")
        XCTAssertTrue(app.textFields["newTopic.name"].waitForExistence(timeout: 15))
        tap("newTopic.create", in: app)
        XCTAssertTrue(element("newTopic.banner", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fix the highlighted fields"].exists)
    }

    @MainActor
    func testOfflineSaysItNeedsAConnection() {
        let app = launch(open: "quickr://t/workout/settings", extra: ["-QuickrSyncControls"])
        XCTAssertTrue(app.buttons["debug.offline"].waitForExistence(timeout: 20))
        app.buttons["debug.offline"].tap()
        let name = field("topicSettings.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        name.typeText(" plan")
        dismissKeyboard(app)
        tap("topicSettings.saveDetails", in: app)
        let banner = element("topicSettings.details.banner", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains("Needs a connection"), banner.label)
    }

    @MainActor
    func testSettingsAtTheLargestTextSize() throws {
        let app = launch(open: "quickr://t/mood/settings", extra: AccessibilityLaunch.arguments())
        XCTAssertTrue(field("topicSettings.name", in: app).waitForExistence(timeout: 15))
        try assertAccessible(app)
        let saveDetails = element("topicSettings.saveDetails", in: app)
        scrollTo(saveDetails, in: app)
        XCTAssertTrue(saveDetails.isHittable)
        // The schedule kind is a menu at this size (TP4), not a segmented control.
        XCTAssertFalse(app.segmentedControls["topicSettings.schedule.kind"].exists)
        let kind = element("topicSettings.schedule.kind", in: app)
        scrollTo(kind, in: app)
        XCTAssertEqual(kind.value as? String, "None", "the menu reports its selection")
        pickScheduleKind("Daily", id: "topicSettings.schedule", in: app)
        XCTAssertEqual(element("topicSettings.schedule.kind", in: app).value as? String, "Daily")
        // TP3: a second time can be removed through a 44 pt target.
        tap("topicSettings.schedule.addTime", in: app)
        let remove = element("topicSettings.schedule.removeTime.1", in: app)
        scrollTo(remove, in: app)
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        try assertAccessible(app, types: .midList)
        // TP1: every weekday is reachable at 44 pt; each group is audited as it shows.
        for day in 1...7 {
            let button = element("topicSettings.schedule.day.\(day)", in: app)
            scrollTo(button, in: app)
            XCTAssertTrue(button.isHittable, "day \(day)")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "day \(day)")
            if day == 4 { try assertAccessible(app, types: .midList) }
        }
        try assertAccessible(app, types: .midList)
        // TP2: the presets are 44 pt.
        for preset in ["Every day", "Weekdays", "Weekends"] {
            let button = element("topicSettings.schedule.preset.\(preset)", in: app)
            scrollTo(button, in: app)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, preset)
        }
        try assertAccessible(app, types: .midList)
        for id in ["topicSettings.saveSchedule", "topicSettings.archive"] {
            scrollTo(element(id, in: app), in: app)
            XCTAssertTrue(element(id, in: app).isHittable, id)
        }
        try assertAccessible(app, types: .midList)
        snap(app, "topic-settings-xxxl")
    }

    @MainActor
    func testNewTopicAndItsScheduleAtTheLargestTextSize() throws {
        let app = launch(open: "quickr://new", extra: AccessibilityLaunch.arguments())
        XCTAssertTrue(app.textFields["newTopic.name"].waitForExistence(timeout: 15))
        try assertAccessible(app)
        let required = element("newTopic.q0.required", in: app)
        scrollTo(required, in: app)
        try assertAccessible(app, types: .midList)
        pickScheduleKind("Every…", id: "newTopic.schedule", in: app)
        let every = element("newTopic.schedule.every", in: app)
        scrollTo(every, in: app)
        XCTAssertTrue(every.isHittable)
        try assertAccessible(app, types: .midList)
        // TP6: a failed create shows the banner. Its VoiceOver focus and announcement are checked by
        // hand (DEVICE-DAY §6); the per-attempt trigger is host-tested (NewTopicModelTests).
        tap("newTopic.create", in: app)
        XCTAssertTrue(element("newTopic.banner", in: app).waitForExistence(timeout: 5))
    }

    /// The schedule kind: a segmented control, or a menu at accessibility sizes.
    @MainActor
    private func pickScheduleKind(_ kind: String, id: String, in app: XCUIApplication) {
        let segmented = app.segmentedControls["\(id).kind"]
        if segmented.exists {
            segmented.buttons[kind].tap()
            return
        }
        let menu = element("\(id).kind", in: app)
        scrollTo(menu, in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "\(id).kind")
        menu.tap()
        let choice = app.buttons[kind].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), kind)
        choice.tap()
    }

    /// The demo screenshots (docs/ios/demo/m2/topic-*.png): run once per appearance.
    @MainActor
    func testScreenshots() {
        let app = launch(open: "quickr://t/workout/settings")
        XCTAssertTrue(field("topicSettings.name", in: app).waitForExistence(timeout: 15))
        snap(app, "topic-settings")
        app.buttons["Daily"].firstMatch.tap()
        scrollTo(element("topicSettings.saveSchedule", in: app), in: app)
        snap(app, "topic-schedule")
        app.terminate()

        let created = launch(open: "quickr://new")
        XCTAssertTrue(created.textFields["newTopic.name"].waitForExistence(timeout: 15))
        snap(created, "topic-new")
    }

    // MARK: Helpers

    @MainActor
    private func launch(open url: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", url] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// A text field, or a text view (a multi-line field).
    @MainActor
    private func field(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[id]
        return field.exists ? field : app.descendants(matching: .any)[id].firstMatch
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

    /// Drags up until `element` exists and is hittable (bounded): a `List` creates rows below the
    /// fold only once they scroll in.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            // Above where a keyboard would be.
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
