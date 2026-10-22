import Foundation
import Observation

/// Whether a text field of the form is being edited, so its keyboard toolbar (and the Save in it,
/// `formSaveBar`) is on screen: with the software keyboard up, minimized, or with a hardware
/// keyboard alike. The keyboard's frame can't tell: minimized or hardware, the keyboard itself is
/// off screen while its toolbar still shows.
///
/// Moving from one field to the next ends one and begins the other in the same main-queue turn:
/// that stays editing, so the bar doesn't flash in between. Only the field that began ends it:
/// another field's end (one first responder at a time, so it ended before this one began) changes
/// nothing. Begins aren't scoped to the form: Record and Edit present nothing with a text field
/// over it (alerts only), and a screen beneath it isn't editing while it's on top.
@MainActor @Observable
public final class FormEditing {
    public private(set) var isEditing = false
    @ObservationIgnored private var ends = 0
    /// The field being edited (its `ObjectIdentifier`).
    @ObservationIgnored private var field: ObjectIdentifier?

    public init() {}

    /// A text field or view began editing.
    public func began(_ field: ObjectIdentifier) {
        ends += 1  // cancels a pending end
        self.field = field
        isEditing = true
    }

    /// One ended editing: not editing any more unless another begins in this same turn.
    public func ended(_ field: ObjectIdentifier) {
        guard field == self.field else { return }
        self.field = nil
        ends += 1
        let end = ends
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ends == end else { return }
            self.isEditing = false
        }
    }
}
