import Foundation
import QuickrCore

/// What `AppearanceEditorView` edits: `NewTopicModel` and `TopicSettingsModel` (appearance.md §7).
@MainActor
public protocol AppearanceEditingModel: AnyObject, Observable {
    var appearance: AppearanceDraft { get set }
    var appearanceErrors: [AppearanceField: String] { get }
    var limits: Limits { get }
    func setAppearanceError(_ message: String?, for field: AppearanceField)
    func setAppearanceErrors(_ errors: [AppearanceField: String])
}

extension AppearanceEditingModel {
    /// "Add" in the tag field: the tag joins the chips, or the field shows why not.
    public func addTag() {
        let message = appearance.addTag(limits: limits)
        setAppearanceError(message, for: .newTag)
    }

    /// A chip's ✕. Indices move, so the per-chip and list errors start over.
    public func removeTag(at index: Int) {
        appearance.removeTag(at: index)
        setAppearanceErrors(
            appearanceErrors.filter { field, _ in
                switch field {
                case .tag, .tags: false
                default: true
                }
            })
    }
}

extension Result where Failure == AppearanceErrors {
    var failureFields: [AppearanceField: String] {
        if case .failure(let errors) = self { return errors.byField }
        return [:]
    }
}
