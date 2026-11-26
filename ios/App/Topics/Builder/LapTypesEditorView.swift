import QuickrCore
import QuickrUI
import SwiftUI

/// The lap types list under the steps (`LapTypesEditor`, timers2.md §1.6): add, rename, reorder,
/// remove. With none, laps are "Lap 1, Lap 2…"; one renames them ("Cig 1, Cig 2"); two or more
/// cycle ("Run 1, Rest 1, Run 2…"). A lap type's key shares the steps' namespace and is shown
/// with its "published" / "new" badge, as a step's is. Identifiers: `<id>.lap<n>.label`,
/// `.menu`, `.key`, `.alerts…` (``AlertsEditor``), `<id>.addLapType`, `<id>.noLapTypes`.
struct LapTypesSection<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let id: String
    var focused: FocusState<UUID?>.Binding
    @QuickrReduceMotion private var reduceMotion

    var body: some View {
        Section {
            if model.draft.laps.isEmpty {
                Text("No lap types: laps are Lap 1, Lap 2…")
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                    .accessibilityIdentifier("\(id).noLapTypes")
            }
            ForEach(Array(model.draft.laps.enumerated()), id: \.element.id) { index, lap in
                TimerItemRow(
                    model: model, item: .lapType(lap.id), owner: .lap(index), tag: "\(id).lap\(index)",
                    noun: "Lap type", index: index, count: model.draft.laps.count, key: lap.key, locked: lap.locked,
                    label: model.lapTypeLabelBinding(lap.id),
                    error: model.draftErrors[.lap(index, .label)] ?? model.draftErrors[.lap(index, .key)],
                    focused: focused, focusId: lap.id,
                    move: { model.draft.moveLapType(lap.id, to: $0) },
                    remove: { model.draft.removeLapType(lap.id) })
            }
            Button {
                withQRAnimation(reduceMotion: reduceMotion) { focused.wrappedValue = model.addLapType() }
            } label: {
                Label("Add lap type", systemImage: "plus")
            }
            .disabled(!model.draft.canAddLapType(limits: model.limits))
            .accessibilityIdentifier("\(id).addLapType")
            TopicFieldError(model.draftErrors[.laps])
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Lap types")
                Text("\(model.draft.laps.count)").font(.qr(.monoCaption))
            }
        } footer: {
            if model.draft.laps.count > 1 {
                Text("Laps cycle through these in order.")
            }
        }
    }
}
