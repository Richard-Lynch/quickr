import Foundation
import QuickrCore

// T2-M3 seam: replaced by the generated `TopicCreateDTO.appearance`/`TopicUpdateDTO.appearance`
// (I3-STORE: `TopicDetailsChange.appearance`, `TopicWrites.updateAppearance`) when M3-DB lands.
// Phase 2 of I3-EDIT folds these two calls into `TopicWriter` and deletes this file.

/// The appearance half of the topic screens' writes (appearance.md §7), bound like ``TopicWriter``
/// to the store the screen was opened from. Online only, like the Details save.
@MainActor
public protocol AppearanceSaving: AnyObject {
    /// "Create topic" with the appearance the topic starts with (`TopicCreate.appearance`).
    func create(_ creation: TopicDraft.Creation, schedule: Schedule?, appearance: TopicAppearance) async
        -> TopicWriteOutcome<Topic>
    /// "Save appearance": `PATCH /topics/{id}` with only the changed fields and
    /// `expected_revision: baseRevision` (the revision on screen).
    func saveAppearance(_ update: AppearanceUpdate, topicId: UUID, baseRevision: Int) async
        -> TopicWriteOutcome<Topic>
}
