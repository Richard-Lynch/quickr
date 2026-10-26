import QuickrCore
import QuickrUI
import SwiftUI

/// The Timed switch and the steps editor (`TimerEditor`, timers.md §2.1, §11.2). A timed topic's
/// entries are runs: Start, then Next through the steps (none makes a plain stopwatch), then Stop.
///
/// A published step keeps its key when renamed, so its stats join across versions; a new step's
/// key follows its label until it is published (a label matching a retired step takes that
/// step's key back). Switching Timed off keeps the steps unsent, and switching it back on
/// restores them. `id` prefixes the accessibility identifiers (`editQuestions.step0.label`).
struct TimerSections<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let id: String
    @FocusState private var focused: DraftStep.ID?
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
                    row(index, step)
                }
                Button {
                    withQRAnimation(reduceMotion: reduceMotion) { focused = model.addStep() }
                } label: {
                    Label("Add step", systemImage: "plus")
                }
                .disabled(!model.draft.canAddStep)
                .accessibilityIdentifier("\(id).addStep")
                TopicFieldError(model.draftErrors[.steps])
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Steps")
                    Text("\(model.draft.steps.count)").font(.qr(.monoCaption))
                }
            }
        }
    }

    /// "Wipe down (step 2)", or "step 2" while it has no name.
    private func name(_ index: Int, _ step: DraftStep) -> String {
        let label = BuilderText.strip(step.label)
        return label.isEmpty ? "step \(index + 1)" : "\(label) (step \(index + 1))"
    }

    private func row(_ index: Int, _ step: DraftStep) -> some View {
        let tag = "\(id).step\(index)"
        let error = model.draftErrors[.step(index, .label)] ?? model.draftErrors[.step(index, .key)]
        return VStack(alignment: .leading, spacing: 4) {
            FieldRow(alignment: .center) {
                Text("\(index + 1)").font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                TextField("Step name", text: model.stepLabelBinding(step.id))
                    .focused($focused, equals: step.id)
                    .submitLabel(.done)
                    .accessibilityLabel("Step \(index + 1) name")
                    .accessibilityIdentifier("\(tag).label")
                Menu {
                    Button("Move up", systemImage: "arrow.up") { model.draft.moveStep(step.id, to: index - 1) }
                        .disabled(index == 0)
                    Button("Move down", systemImage: "arrow.down") { model.draft.moveStep(step.id, to: index + 1) }
                        .disabled(index == model.draft.steps.count - 1)
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        withQRAnimation(reduceMotion: reduceMotion) { model.draft.removeStep(step.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.qr.muted)
                        .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Step actions: \(name(index, step))")
                .accessibilityIdentifier("\(tag).menu")
            }
            HStack(spacing: 8) {
                Text(step.key.isEmpty ? "—" : step.key)
                    .font(.qr(.monoCaption))
                    .foregroundStyle(.qr.muted)
                    .accessibilityLabel("Key \(step.key.isEmpty ? "none yet" : step.key)")
                    .accessibilityIdentifier("\(tag).key")
                QuickrBadge(step.locked ? "published" : "new", tone: step.locked ? .neutral : .accent)
            }
            TopicFieldError(error)
        }
        .padding(.vertical, 2)
    }
}
