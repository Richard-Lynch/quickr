import Foundation
import Observation

/// Whether a text field of the form is being edited, so its keyboard toolbar (and the Save in it,
/// `formSaveBar`) is on screen: with the software keyboard up, minimized, or with a hardware
/// keyboard alike. The keyboard's frame can't tell: minimized or hardware, the keyboard itself is
/// off screen while its toolbar still shows.
///
/// Moving from one field to the next ends one and begins the other in the same main-queue turn:
/// that stays editing, so the bar doesn't flash in between.
@MainActor @Observable
public final class FormEditing {
    public private(set) var isEditing = false
    @ObservationIgnored private var ends = 0

    public init() {}

    /// A text field or view began editing.
    public func began() {
        ends += 1  // cancels a pending end
        isEditing = true
    }

    /// One ended editing: not editing any more unless another begins in this same turn.
    public func ended() {
        ends += 1
        let end = ends
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ends == end else { return }
            self.isEditing = false
        }
    }
}
