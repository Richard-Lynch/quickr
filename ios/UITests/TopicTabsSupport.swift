import XCTest

/// The topic's tabs and other short choices drawn with `QuickrSegmentedPicker`: a segmented
/// control at the standard text sizes, a menu button at accessibility sizes (a11y audit B1). These
/// work for either, so a test needn't know which size it runs at.
extension XCTestCase {
    /// Opens a topic tab: "Overview", "Entries" or "Versions".
    @MainActor
    func selectTopicTab(_ tab: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        selectChoice(tab, in: "topic.tabs", app: app, file: file, line: line)
    }

    /// The selected topic tab's name, or nil when the tabs aren't on screen.
    @MainActor
    func selectedTopicTab(in app: XCUIApplication, timeout: TimeInterval = 5) -> String? {
        selectedChoice(in: "topic.tabs", app: app, timeout: timeout)
    }

    /// Picks `option` in the `QuickrSegmentedPicker` whose identifier is `id`.
    @MainActor
    func selectChoice(
        _ option: String, in id: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let picker = choicePicker(id, app: app, timeout: 10) else {
            XCTFail("No \(id) on screen", file: file, line: line)
            return
        }
        if picker.elementType == .segmentedControl {
            picker.buttons[option].tap()
            return
        }
        picker.tap()
        // The menu's items are buttons named by their options, over the screen.
        let item = app.buttons.matching(NSPredicate(format: "label == %@", option)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(id) offers \(option)", file: file, line: line)
        item.tap()
    }

    /// The selected option of the `QuickrSegmentedPicker` whose identifier is `id`.
    @MainActor
    func selectedChoice(in id: String, app: XCUIApplication, timeout: TimeInterval = 5) -> String? {
        guard let picker = choicePicker(id, app: app, timeout: timeout) else { return nil }
        if picker.elementType == .segmentedControl {
            let selected = picker.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
            return selected.exists ? selected.label : nil
        }
        // A menu picker's value is its selected option (the app sets it); else its label shows it.
        if let value = picker.value as? String, !value.isEmpty { return value }
        return picker.label
    }

    /// The picker, as whichever it is now: the segmented control or the menu's button.
    @MainActor
    private func choicePicker(_ id: String, app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let segmented = app.segmentedControls[id]
        let menu = app.buttons[id]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if segmented.exists { return segmented }
            if menu.exists { return menu }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }
}
