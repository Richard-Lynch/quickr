import XCTest

/// BUILDER-UI against the fake server (`-QuickrUITest`, https://quickr.test): editing a topic's
/// questions into v2 (review, change note, publish, the Versions tab), a conflict with a version
/// published elsewhere (load the latest), the builder's preview and collapsing cards, and the
/// Versions tab.
final class BuilderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEditQuestionsPublishesV2() {
        let app = launch(open: "quickr://t/mood/edit")
        let header = element("editQuestions.q0.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        XCTAssertEqual(header.value as? String, "Collapsed", "a published topic opens with its cards closed")

        addQuestion("int", label: "Energy", in: app)
        tap("editQuestions.review", in: app)

        let headline = element("review.headline", in: app)
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertTrue(headline.label.contains("Ready to publish as v2"), headline.label)
        XCTAssertTrue(app.staticTexts["Energy"].firstMatch.exists, "the change names the new question")
        snap(app, "builder-review")  // before the keyboard comes up
        let note = field("review.note", in: app)
        note.tap()
        note.typeText("Track energy too")
        let publish = app.buttons["review.publish"]
        XCTAssertEqual(publish.label, "Publish v2")
        publish.tap()

        XCTAssertTrue(toast("Published v2", in: app).waitForExistence(timeout: 10))
        // The Versions tab, with v2 current once the pull brings its row.
        let v2 = element("versions.v2", in: app)
        XCTAssertTrue(v2.waitForExistence(timeout: 15))
        XCTAssertTrue(v2.label.contains("current"), v2.label)
        XCTAssertTrue(v2.label.contains("Track energy too"), v2.label)
        XCTAssertTrue(element("versions.v1", in: app).exists)
        XCTAssertFalse(element("versions.pending", in: app).exists)
        // Back goes to where the editor was opened from, not to the editor.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAConflictLoadsTheLatestVersion() {
        let app = launch(open: "quickr://t/workout/edit", extra: ["-QuickrStalePublish"])
        XCTAssertTrue(element("editQuestions.q0.header", in: app).waitForExistence(timeout: 15))
        addQuestion("str", label: "Notes", in: app)
        tap("editQuestions.review", in: app)

        // Someone else published v2 meanwhile.
        let reload = app.buttons["conflict.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        snap(app, "builder-conflict")
        reload.tap()
        XCTAssertTrue(toast("Loaded v2", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(reload.exists)
        // The editor starts over from v2: its new question is published, the draft's is gone.
        let third = element("editQuestions.q2.header", in: app)
        scrollTo(third, in: app)
        XCTAssertTrue(third.label.contains("Energy"), third.label)
        XCTAssertTrue(third.label.contains("published"), third.label)
        XCTAssertFalse(element("editQuestions.q3.header", in: app).exists)
        let intro = element("editQuestions.intro", in: app)
        scrollTo(intro, in: app, up: true)
        XCTAssertTrue(intro.label.contains("Publishing creates v3"), intro.label)
    }

    @MainActor
    func testKeepingTheDraftAfterAConflict() {
        let app = launch(open: "quickr://t/mood/edit", extra: ["-QuickrStalePublish"])
        XCTAssertTrue(element("editQuestions.q0.header", in: app).waitForExistence(timeout: 15))
        addQuestion("int", label: "Sleep", in: app)
        tap("editQuestions.review", in: app)
        let keep = app.buttons["conflict.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        keep.tap()
        XCTAssertFalse(keep.waitForExistence(timeout: 2))
        let added = element("editQuestions.q1.header", in: app)
        scrollTo(added, in: app)
        XCTAssertTrue(added.label.contains("Sleep"), "the draft is still there to copy from")
    }

    @MainActor
    func testPreviewAndCollapse() {
        let app = launch(open: "quickr://new")
        let label = app.textFields["newTopic.q0.label"]
        XCTAssertTrue(label.waitForExistence(timeout: 15))
        label.tap()
        label.typeText("Glasses of water\n")  // Return puts the keyboard away
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        snap(app, "builder-edit")

        // The preview shows the question as the record screen will.
        pane("newTopic", "Preview", in: app)
        XCTAssertTrue(element("newTopic.preview", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Glasses of water"].firstMatch.exists)
        XCTAssertFalse(app.textFields["newTopic.q0.label"].exists)
        snap(app, "builder-preview")

        // Back to the editor; with two questions, Collapse all closes every card.
        pane("newTopic", "Edit", in: app)
        addQuestion("enum", label: "Mood", prefix: "newTopic", in: app)
        let toggleAll = app.buttons["newTopic.toggleAll"]
        scrollTo(toggleAll, in: app, up: true)
        XCTAssertEqual(toggleAll.label, "Collapse all")
        toggleAll.tap()
        XCTAssertEqual(element("newTopic.q0.header", in: app).value as? String, "Collapsed")
        XCTAssertFalse(app.textFields["newTopic.q0.label"].exists)
        XCTAssertEqual(toggleAll.label, "Expand all")
        element("newTopic.q0.header", in: app).tap()
        XCTAssertTrue(app.textFields["newTopic.q0.label"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVersionsTab() {
        let app = launch(open: "quickr://t/workout/versions")
        let v1 = element("versions.v1", in: app)
        XCTAssertTrue(v1.waitForExistence(timeout: 15))
        XCTAssertTrue(v1.label.contains("current"), v1.label)
        XCTAssertTrue(v1.label.contains("Initial version"), v1.label)
        XCTAssertEqual(v1.value as? String, "Expanded", "the current version starts open")
        let duration = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Duration'"))
        XCTAssertTrue(duration.firstMatch.exists, "its questions show")
        snap(app, "versions")
        v1.tap()
        XCTAssertEqual(v1.value as? String, "Collapsed")
        tap("versions.new", in: app)
        XCTAssertTrue(element("editQuestions.q0.header", in: app).waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    /// "Add question" → `type`, then types its label into the new (open) card.
    @MainActor
    private func addQuestion(
        _ type: String, label: String, prefix: String = "editQuestions", in app: XCUIApplication
    ) {
        let count = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH '.header'", "\(prefix).q")
        ).count
        tap("\(prefix).addQuestion", in: app)
        // The dialog's buttons can appear twice in the tree (the sheet and its presentation).
        let choice = app.buttons["\(prefix).addQuestion.\(type)"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        let field = app.textFields["\(prefix).q\(count).label"]
        scrollTo(field, in: app, up: true)
        scrollTo(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(label)
        dismissKeyboard(app)
    }

    /// Picks the builder's Edit or Preview pane.
    @MainActor
    private func pane(_ prefix: String, _ name: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["\(prefix).pane"]
        scrollTo(picker, in: app, up: true)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons[name].tap()
    }

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

    /// Drags until `element` exists and is hittable (bounded): a `List` creates rows only once
    /// they scroll in. Down the list by default; `up` toward its top.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            // Above where a keyboard would be.
            let (from, to) = up ? (0.2, 0.55) : (0.45, 0.12)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
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
