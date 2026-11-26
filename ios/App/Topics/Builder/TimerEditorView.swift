import QuickrCore
import QuickrUI
import SwiftUI

/// The Timed switch and the timer's editors (`TimerEditor`, timers.md §2.1, §11.2, timers2.md
/// §1.6): the steps, the lap types, the variables, and each step's and lap type's alerts. A timed
/// topic's entries are runs: Start, then Next through the steps (none makes a plain stopwatch),
/// then Stop; laps cycle through the lap types.
///
/// A published step or lap type keeps its key when renamed, so its stats join across versions; a
/// new one's key follows its label until it is published (a label matching a retired one of its
/// kind takes that key back), and steps and lap types never share a key. Switching Timed off keeps
/// the timer's lists unsent, and switching it back on restores them. `id` prefixes the
/// accessibility identifiers (`editQuestions.step0.label`, `editQuestions.lap1.alert0.at`,
/// `editQuestions.variable0.name`).
struct TimerSections<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let id: String
    @FocusState private var focused: UUID?
    @QuickrReduceMotion private var reduceMotion

    var body: some View {
        Section {
            Toggle(isOn: model.timedBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timed").font(.qr(.label))
                    Text(
                        model.draft.timed
                            ? "Each entry is a run: Start, Next through the steps, then Stop."
                            : "Time each entry with Start and Stop, and optional named steps."
                    )
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                }
            }
            .accessibilityIdentifier("\(id).timed")
        } header: {
            Text("Timing")
        }
        if model.draft.timed {
            Section {
                if model.draft.steps.isEmpty {
                    Text("No steps: a plain stopwatch, with laps.")
                        .font(.qr(.subheadline))
                        .foregroundStyle(.qr.muted)
                        .accessibilityIdentifier("\(id).noSteps")
                }
                ForEach(Array(model.draft.steps.enumerated()), id: \.element.id) { index, step in
                    TimerItemRow(
                        model: model, item: .step(step.id), owner: .step(index), tag: "\(id).step\(index)",
                        noun: "Step", index: index, count: model.draft.steps.count, key: step.key,
                        locked: step.locked, label: model.stepLabelBinding(step.id),
                        error: model.draftErrors[.step(index, .label)] ?? model.draftErrors[.step(index, .key)],
                        focused: $focused, focusId: step.id,
                        move: { model.draft.moveStep(step.id, to: $0) },
                        remove: { model.draft.removeStep(step.id) })
                }
                Button {
                    withQRAnimation(reduceMotion: reduceMotion) { focused = model.addStep() }
                } label: {
                    Label("Add step", systemImage: "plus")
                }
                .disabled(!model.draft.canAddStep(limits: model.limits))
                .accessibilityIdentifier("\(id).addStep")
                TopicFieldError(model.draftErrors[.steps])
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Steps")
                    Text("\(model.draft.steps.count)").font(.qr(.monoCaption))
                }
            }
            LapTypesSection(model: model, id: id, focused: $focused)
            VariablesSection(model: model, id: id)
        }
    }
}

/// One step or lap type (`TimerItemRow`): its name, a menu to move or remove it, its key with a
/// "published" / "new" badge, and its alerts behind a disclosure that shows their count while
/// closed and opens itself while one of them has an error.
struct TimerItemRow<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let item: TimerItemID
    let owner: AlertOwner
    /// The accessibility identifier prefix: `newTopic.step0`, `editQuestions.lap1`.
    let tag: String
    /// "Step" or "Lap type".
    let noun: String
    let index: Int
    let count: Int
    let key: String
    let locked: Bool
    let label: Binding<String>
    let error: String?
    var focused: FocusState<UUID?>.Binding
    let focusId: UUID
    let move: (Int) -> Void
    let remove: () -> Void
    @QuickrReduceMotion private var reduceMotion

    /// "Wipe down (step 2)", or "step 2" while it has no name.
    private var name: String {
        let text = BuilderText.strip(label.wrappedValue)
        let place = "\(noun.lowercased()) \(index + 1)"
        return text.isEmpty ? place : "\(text) (\(place))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldRow(alignment: .center) {
                Text("\(index + 1)").font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                TextField("\(noun) name", text: label)
                    .focused(focused, equals: focusId)
                    .submitLabel(.done)
                    .accessibilityLabel("\(noun) \(index + 1) name")
                    .accessibilityIdentifier("\(tag).label")
                Menu {
                    Button("Move up", systemImage: "arrow.up") { move(index - 1) }
                        .disabled(index == 0)
                    Button("Move down", systemImage: "arrow.down") { move(index + 1) }
                        .disabled(index == count - 1)
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        withQRAnimation(reduceMotion: reduceMotion) { remove() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.qr.muted)
                        .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(noun) actions: \(name)")
                .accessibilityIdentifier("\(tag).menu")
            }
            HStack(spacing: 8) {
                Text(key.isEmpty ? "—" : key)
                    .font(.qr(.monoCaption))
                    .foregroundStyle(.qr.muted)
                    .accessibilityLabel("Key \(key.isEmpty ? "none yet" : key)")
                    .accessibilityIdentifier("\(tag).key")
                QuickrBadge(locked ? "published" : "new", tone: locked ? .neutral : .accent)
            }
            TopicFieldError(error)
            AlertsEditor(model: model, item: item, owner: owner, tag: tag, ownerName: name)
        }
        .padding(.vertical, 2)
    }
}
