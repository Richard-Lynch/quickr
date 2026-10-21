import XCTest

/// Entries, Edit and Export's known accessibility issues at the largest text size (a11y audit,
/// slice B): each names its finding, and the lists only shrink (`assertAccessible`).
enum EntriesAccessibility {
    static let list: [KnownAccessibilityIssue] = []
    static let edit: [KnownAccessibilityIssue] = []
    static let export: [KnownAccessibilityIssue] = []
}
