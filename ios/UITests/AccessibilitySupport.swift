import XCTest

/// Shared accessibility helpers for the UI tests (docs/ios/reviews/a11y-audit.md, test plan).
///
/// - ``AccessibilityLaunch`` builds the launch arguments for a text size and for Reduce Motion.
/// - ``XCTestCase/assertAccessible(_:types:allowing:within:file:line:)`` runs
///   `performAccessibilityAudit` with the default audit types, minus a short allow-list of
///   known issues. Each allowed issue names its finding in the audit doc and must still occur:
///   an entry that matches nothing fails the test, so fixing an issue removes its entry and the
///   list only shrinks.
enum AccessibilityLaunch {
    /// The largest accessibility text size, the one every screen is audited at.
    static let xxxl = "UICTContentSizeCategoryAccessibilityXXXL"
    /// The default text size.
    static let large = "UICTContentSizeCategoryL"

    /// Launch arguments for `contentSize` (a `UICTContentSizeCategory…` name) and, with
    /// `reduceMotion`, QuickrUI's DEBUG Reduce Motion override (`QuickrMotion.reduceMotionArgument`;
    /// the system setting can't be changed from a test).
    static func arguments(contentSize: String? = xxxl, reduceMotion: Bool = false) -> [String] {
        var arguments: [String] = []
        if let contentSize { arguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        if reduceMotion { arguments.append("-QuickrReduceMotion") }
        return arguments
    }
}

/// An audit issue a test accepts for now. `finding` is its id in docs/ios/reviews/a11y-audit.md.
/// It matches an issue of `type` on an element whose identifier equals `element`, or whose label
/// contains it.
struct KnownAccessibilityIssue: CustomStringConvertible {
    var finding: String
    var type: XCUIAccessibilityAuditType
    var element: String
    var reason: String

    init(_ finding: String, _ type: XCUIAccessibilityAuditType, element: String, reason: String) {
        self.finding = finding
        self.type = type
        self.element = element
        self.reason = reason
    }

    var description: String { "\(finding) on \"\(element)\" (\(reason))" }
}

extension XCUIAccessibilityAuditType {
    /// What every screen is audited for. `.contrast` is left out until the palette is checked
    /// on its own; `.action` and `.parentChild` report SwiftUI internals.
    static let quickrDefault: XCUIAccessibilityAuditType = [
        .dynamicType, .textClipped, .hitRegion, .elementDetection, .sufficientElementDescription, .trait,
    ]

    /// What a screen audits partway down a `List` (A11Y slice C). The audit's Dynamic Type check
    /// steps the text size itself, which re-lays the List out mid-audit: rows land under the
    /// translucent bar (flagged as clipped text) or the List blanks (flagged as unsupported Dynamic
    /// Type), with no element to scope, differently each run. So mid-list audits check only what is
    /// tied to an element; text size and clipping are audited at the top of each screen, asserted
    /// geometrically (full width, wrapping, 44 pt, hittable) mid-list, and checked by hand at XXXL
    /// (docs/ios/reviews/a11y-audit.md, slice C; DEVICE-DAY §6).
    static let midList: XCUIAccessibilityAuditType = [.hitRegion, .sufficientElementDescription, .trait]
}

extension XCTestCase {
    /// Audits what `app` shows now. Fails for every issue not in `known` (and, with `within`, touching
    /// one of those frames: a test that owns only part of the screen), and for every `known` entry
    /// that no longer occurs. Attaches the issues it accepted.
    @MainActor
    func assertAccessible(
        _ app: XCUIApplication, types: XCUIAccessibilityAuditType = .quickrDefault,
        allowing known: [KnownAccessibilityIssue] = [], within frames: [CGRect]? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var used = Set<Int>()
        var accepted: [String] = []
        var unexpected: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            guard let element = issue.element else { return false }
            let frame = element.frame
            // Not ours unless it touches one of the frames (an overflow across the edge counts).
            if let frames, !frames.contains(where: { $0.intersects(frame) || $0.contains(frame.origin) }) {
                return true
            }
            let identifier = element.identifier
            let label = element.label
            guard
                let index = known.indices.first(where: { index in
                    let entry = known[index]
                    return issue.auditType == entry.type
                        && (identifier == entry.element || (!entry.element.isEmpty && label.contains(entry.element)))
                })
            else {
                // Reported below with the element, which the audit's own failure leaves out.
                unexpected.append("\(issue.compactDescription) [\(identifier) \"\(label)\" \(frame)]")
                return true
            }
            used.insert(index)
            accepted.append("\(known[index].finding): \(issue.compactDescription) [\(identifier) \"\(label)\"]")
            return true
        }
        for issue in unexpected {
            XCTFail("Accessibility audit: \(issue)", file: file, line: line)
        }
        for (index, entry) in known.enumerated() where !used.contains(index) {
            XCTFail("Known accessibility issue no longer occurs; remove it: \(entry)", file: file, line: line)
        }
        if !accepted.isEmpty {
            let attachment = XCTAttachment(string: accepted.joined(separator: "\n"))
            attachment.name = "accepted accessibility issues"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

extension XCTestCase {
    /// Nudges the list (bounded) until every element sits wholly between the navigation bar and the
    /// bottom of the window, with `margin` to spare (a drag can land a few points short), then
    /// asserts that they do.
    @MainActor
    func bringIntoFullView(
        _ elements: [XCUIElement], in app: XCUIApplication, margin: CGFloat = 24,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.windows.firstMatch.frame.maxY
        for _ in 0..<8 {
            let minY = elements.map(\.frame.minY).min() ?? top
            let maxY = elements.map(\.frame.maxY).max() ?? bottom
            let down: CGFloat
            if minY < top + margin / 2 {
                down = -(top + margin - minY)  // drag down: content moves down
            } else if maxY > bottom - margin / 2 {
                down = maxY - (bottom - margin)
            } else {
                break
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -down)))
        }
        for element in elements {
            let name = element.identifier
            XCTAssertGreaterThanOrEqual(element.frame.minY, top, "\(name) under the bar", file: file, line: line)
            XCTAssertLessThanOrEqual(element.frame.maxY, bottom, "\(name) below the window", file: file, line: line)
        }
    }
}
