import XCTest

extension XCUIAccessibilityAuditType {
    /// What the topic screens audit partway down a `List` (A11Y slice C). The audit's Dynamic Type
    /// check steps the text size itself, which re-lays the List out mid-audit: rows land under the
    /// translucent bar (flagged as clipped text) or the List blanks (flagged as unsupported Dynamic
    /// Type), with no element to scope, differently each run. So mid-list audits check only what is
    /// tied to an element; text size and clipping are audited at the top of each screen, asserted
    /// geometrically (44 pt, stacking, hittable) mid-list, and checked by hand at XXXL
    /// (docs/ios/reviews/a11y-audit.md, slice C; DEVICE-DAY §6).
    static let topicsMidList: XCUIAccessibilityAuditType = [.hitRegion, .sufficientElementDescription, .trait]
}
