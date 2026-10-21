import Foundation
import QuickrUI
import Testing

/// `FormEditing`: what `formSaveBar` decides by (SAVE-KBD). The bar shows only while nothing is
/// being edited, whatever the keyboard's frame (minimized or hardware, the keyboard is off screen
/// while its toolbar's Save still shows).
@MainActor @Suite struct FormEditingTests {
    /// Lets the main queue run what was queued before this call.
    func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func editingShowsTheToolbarSaveAndEndingTheBar() async {
        let editing = FormEditing()
        #expect(!editing.isEditing)
        editing.began()
        #expect(editing.isEditing)
        editing.ended()
        await nextTurn()
        #expect(!editing.isEditing)
    }

    /// Next/Return or a tap on another field: one ends and the next begins in the same turn. The
    /// bar never shows in between (two Saves for a frame).
    @Test func movingBetweenFieldsStaysEditing() async {
        let editing = FormEditing()
        editing.began()
        editing.ended()
        #expect(editing.isEditing, "an end waits for the turn to finish")
        editing.began()
        #expect(editing.isEditing)
        await nextTurn()
        #expect(editing.isEditing)
        editing.ended()
        await nextTurn()
        #expect(!editing.isEditing)
    }

    /// A begin queued after an end: the end's turn comes first, then it's editing again.
    @Test func aBeginInALaterTurnEditsAgain() async {
        let editing = FormEditing()
        editing.began()
        editing.ended()
        await nextTurn()
        #expect(!editing.isEditing)
        editing.began()
        #expect(editing.isEditing)
    }
}
