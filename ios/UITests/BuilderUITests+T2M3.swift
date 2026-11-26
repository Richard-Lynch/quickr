import XCTest

// T2-M3 (appearance.md §7, §6.3, §16): a colour, an emoji and two tags picked in New topic show in
// the topic's header. The tile's glyph and tinted bar wait for T2-WIRE-I (M2 hasn't wired the theme).
extension BuilderUITests {
    /// §16 `BuilderUITests`: New topic → Appearance: teal, 🏃 and the tags Health and Daily. The row's
    /// summary reads them back; once created, the topic's header shows the name after the glyph and
    /// the two chips in order, and its settings read the stored appearance back.
    ///
    /// The glyph and the tint rule are hidden from accessibility (they repeat the name), so the
    /// emoji is checked where it is spoken (the Appearance row's summary, before Create and again in
    /// the topic's settings, from the stored topic) and, in the header, by the name's place: it
    /// starts after the 28 pt glyph and its spacing, not at the row's leading padding.
    @MainActor
    func testNewTopicWithAppearance() {
        XCUIDevice.shared.appearance = .light
        let app = launchForAppearance()
        pickAppearance(name: "Sauna", color: "teal", icon: "🏃", tags: ["Health", "Daily"], in: app)
        XCTAssertEqual(node("topic.color.teal", in: app).isSelected, true, "the swatch is chosen")
        XCTAssertFalse(node("topic.color.none", in: app).isSelected)
        capture(app, "appearance-editor")

        backToNewTopic(in: app)
        let row = node("newTopic.appearance", in: app)
        XCTAssertTrue(row.label.contains("Teal · 🏃 · 2 tags"), row.label)
        createAndOpen("sauna", in: app)

        let header = node("topic.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 10), "a topic with an appearance has a header")
        let name = node("topic.header.name", in: app)
        XCTAssertEqual(name.label, "Sauna")
        // 16 pt padding + the 28 pt glyph + 10 pt spacing (a point of slack for rounding).
        XCTAssertGreaterThanOrEqual(
            name.frame.minX - header.frame.minX, 53, "the glyph sits before the name: \(name.frame) in \(header.frame)")
        XCTAssertTrue(node("topic.header.tags", in: app).exists)
        XCTAssertEqual(node("topic.header.tags.0", in: app).label, "Health")
        XCTAssertEqual(node("topic.header.tags.1", in: app).label, "Daily")
        XCTAssertFalse(node("topic.header.tags.2", in: app).exists)
        XCTAssertLessThan(header.frame.maxY, node("topic.tabs", in: app).frame.minY, "above the tabs")
        capture(app, "appearance-header")

        // Stored: the settings' Appearance row reads the topic back.
        touch("topic.settings", in: app)
        let stored = node("topicSettings.appearance", in: app)
        slide(to: stored, in: app)
        XCTAssertTrue(stored.waitForExistence(timeout: 10))
        XCTAssertTrue(stored.label.contains("Teal · 🏃 · 2 tags"), stored.label)
    }

    /// The evidence shots (docs/t2/evidence/M3a): the editor and the header for three colours, in
    /// light and dark, and at the largest text size.
    @MainActor
    func testAppearanceInLightDarkAndTheLargestTextSize() {
        let looks: [(color: String, icon: String, name: String, tags: [String])] = [
            ("teal", "💧", "Water", ["Health", "Daily"]),
            ("orange", "🚬", "Smoking", ["Habit"]),
            ("violet", "🧘", "Meditate", ["Mind", "Morning"]),
        ]
        let modes: [(name: String, appearance: XCUIDevice.Appearance, extra: [String])] = [
            ("light", .light, []), ("dark", .dark, []), ("xxxl", .light, AccessibilityLaunch.arguments()),
        ]
        for look in looks {
            for mode in modes {
                XCUIDevice.shared.appearance = mode.appearance
                let app = launchForAppearance(extra: mode.extra)
                pickAppearance(name: look.name, color: look.color, icon: look.icon, tags: look.tags, in: app)
                capture(app, "appearance-editor-\(look.color)-\(mode.name)")
                backToNewTopic(in: app)
                createAndOpen(look.name.lowercased(), in: app)
                XCTAssertTrue(node("topic.header", in: app).waitForExistence(timeout: 10), "\(look.color) \(mode.name)")
                XCTAssertEqual(node("topic.header.name", in: app).label, look.name)
                capture(app, "appearance-header-\(look.color)-\(mode.name)")
                app.terminate()
            }
        }
        XCUIDevice.shared.appearance = .light
    }

    // MARK: T2-M3 helpers

    @MainActor
    private func launchForAppearance(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://new"] + extra
        app.launch()
        return app
    }

    /// Names the new topic, then opens its Appearance editor and picks `color`, types `icon` and adds
    /// `tags`, each typed once (no emoji pane under XCUITest: `typeText` types the emoji).
    @MainActor
    private func pickAppearance(name: String, color: String, icon: String, tags: [String], in app: XCUIApplication) {
        let field = app.textFields["newTopic.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(name)
        closeKeyboard(app)
        touch("newTopic.appearance", in: app)
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5), "the editor")

        touch("topic.color.\(color)", in: app)
        let emoji = app.textFields["topic.icon"]
        slide(to: emoji, in: app)
        emoji.tap()
        emoji.typeText(icon)
        XCTAssertEqual(emoji.value as? String, icon)
        closeKeyboard(app)

        let add = app.textFields["topic.tags.add"]
        slide(to: add, in: app)
        add.tap()
        // Return adds the tag and keeps the field for the next one.
        for tag in tags { add.typeText(tag + "\n") }
        closeKeyboard(app)
        for (index, tag) in tags.enumerated() {
            let chip = node("topic.tags.\(index)", in: app)
            slide(to: chip, in: app, up: true)
            XCTAssertEqual(chip.label, "Remove tag \(tag)")
        }
        XCTAssertFalse(node("topic.tags.\(tags.count)", in: app).exists)
        // The swatch row, back in view for the shot.
        slide(to: node("topic.color.\(color)", in: app), in: app, up: true)
    }

    @MainActor
    private func backToNewTopic(in app: XCUIApplication) {
        app.navigationBars["Appearance"].buttons.element(boundBy: 0).tap()
        let row = node("newTopic.appearance", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back on New topic")
    }

    /// Creates the topic (no questions: back on the list) and opens it from its tile's title.
    @MainActor
    private func createAndOpen(_ slug: String, in app: XCUIApplication) {
        touch("newTopic.create", in: app)
        let toast = app.descendants(matching: .any).matching(identifier: "toast.text")
            .matching(NSPredicate(format: "label BEGINSWITH 'Topic created'")).firstMatch
        let banner = node("newTopic.banner", in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 10), banner.exists ? "banner: \(banner.label)" : "no toast")
        let tile = node("tile.\(slug)", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "back on the list")
        slide(to: tile, in: app)
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        XCTAssertTrue(node("topic.tabs", in: app).waitForExistence(timeout: 10), "the topic's screen")
    }

    @MainActor
    private func node(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func touch(_ id: String, in app: XCUIApplication) {
        let target = node(id, in: app)
        slide(to: target, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), id)
        target.tap()
    }

    /// Drags until `element` exists and is whole on screen (bounded): a `List` creates rows only once
    /// they scroll in. Down by default; `up` toward the top.
    @MainActor
    private func slide(to element: XCUIElement, in app: XCUIApplication, up: Bool = false) {
        for _ in 0..<12 where !(element.exists && element.isHittable && app.frame.contains(element.frame)) {
            let (from, to) = up ? (0.2, 0.55) : (0.45, 0.12)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
    }

    /// Puts the keyboard away and checks it went, as `TopicUITests.dismissKeyboard` (#238): a tap on
    /// the bar doesn't end editing in SwiftUI, a drag down into the keyboard does
    /// (`.scrollDismissesKeyboard(.interactively)`).
    @MainActor
    private func closeKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        app.navigationBars.firstMatch.tap()
        if keyboard.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the keyboard closes")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
