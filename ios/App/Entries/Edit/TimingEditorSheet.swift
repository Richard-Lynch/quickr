import QuickrCore
import QuickrUI
import SwiftUI

/// The Edit times sheet (the PWA's `TimingEditor`): the start, each segment's step (or lap) and
/// end, the steps without a segment (skipped or not reached), and the pauses. Durations update as
/// you type; Save sends the whole edit, checked first with the server's rules.
struct TimingEditorSheet: View {
    @Bindable var editor: TimingEditModel
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if editor.isStale {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(TimingEditModel.staleTitle).font(.qr(.label))
                            Text(TimingEditModel.staleText).font(.qr(.subheadline))
                            Button {
                                Task { await editor.reload() }
                            } label: {
                                HStack {
                                    if editor.isReloading { ProgressView() }
                                    Text("Reload times")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(editor.isReloading)
                            .accessibilityIdentifier("timing.reload")
                        }
                        .listRowBackground(Color.qr.warnSoft)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("timing.stale")
                    }
                } else if let message = editor.serverMessage {
                    Section {
                        Text(message).font(.qr(.label)).foregroundStyle(.qr.danger)
                            .accessibilityIdentifier("timing.banner")
                    }
                }
                if let error = editor.formError {
                    Section { Text(error).foregroundStyle(.qr.danger) }
                }
                Section {
                    timeField(
                        "Started", text: $editor.draft.startedAt, path: "started_at", id: "timing.startedAt")
                } footer: {
                    Text("The run’s end is the entry’s time. Later taps on this run are ignored once you save.")
                }
                segments
                if !editor.unreached.isEmpty { skips }
                pauses
                Section {
                    let checked = editor.checked
                    HStack {
                        Text("Total")
                        Spacer()
                        Text(checked.activeMs.map(DurationFormat.format) ?? "—").font(.qr(.mono))
                            .accessibilityIdentifier("timing.total")
                        if let paused = checked.pausedMs, paused > 0 {
                            Text("· \(DurationFormat.format(paused)) paused").foregroundStyle(.qr.muted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .disabled(editor.isSaving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("timing.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if editor.isSaving { ProgressView() } else { Text("Save times") }
                    }
                    .disabled(editor.isStale || editor.isSaving || editor.isReloading)
                    .accessibilityIdentifier("timing.save")
                }
            }
            .interactiveDismissDisabled(editor.isSaving)
        }
    }

    private var segments: some View {
        Section("Segments") {
            let checked = editor.checked
            ForEach(Array(editor.draft.segments.enumerated()), id: \.element.id) { i, segment in
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Segment \(i + 1)", selection: stepBinding(i)) {
                        ForEach(editor.steps, id: \.key) { Text($0.label).tag(String?.some($0.key)) }
                        if let step = segment.step, !editor.steps.contains(where: { $0.key == step }) {
                            Text(step).tag(String?.some(step))
                        }
                        Text("Lap").tag(String?.none)
                    }
                    .accessibilityIdentifier("timing.segment\(i).step")
                    errorText("segments.\(i).step")
                    timeField(
                        "Ended", text: endBinding(i), path: "segments.\(i).ended_at", id: "timing.segment\(i).end",
                        hint: checked.segments.indices.contains(i) ? hint(checked.segments[i]) : nil)
                }
                .swipeActions {
                    if editor.draft.segments.count > 1 {
                        Button("Remove", role: .destructive) { editor.draft.segments.remove(at: i) }
                    }
                }
            }
            Button {
                editor.draft.addSegment(steps: editor.steps)
            } label: {
                Label("Add segment", systemImage: "plus")
            }
            .accessibilityIdentifier("timing.addSegment")
        }
    }

    private var skips: some View {
        Section {
            ForEach(editor.unreached, id: \.key) { step in
                let at = editor.draft.skipped.firstIndex(of: step.key)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Skipped \(step.label)",
                        isOn: Binding(
                            get: { editor.draft.skipped.contains(step.key) },
                            set: { editor.draft.setSkipped(step.key, $0, steps: editor.steps) }))
                    if let at { errorText("skipped.\(at)") }
                }
            }
        } header: {
            Text("Steps without a segment")
        } footer: {
            Text("Tick a step that was skipped; leave it clear if the run stopped before it.")
        }
    }

    private var pauses: some View {
        Section("Pauses") {
            if editor.draft.pauses.isEmpty {
                Text("No pauses.").foregroundStyle(.qr.muted)
            }
            ForEach(Array(editor.draft.pauses.enumerated()), id: \.element.id) { i, _ in
                VStack(alignment: .leading, spacing: 6) {
                    timeField(
                        "Pause \(i + 1) started", text: pauseBinding(i, \.start), path: "pauses.\(i).start",
                        id: "timing.pause\(i).start")
                    timeField(
                        "Pause \(i + 1) ended", text: pauseBinding(i, \.end), path: "pauses.\(i).end",
                        id: "timing.pause\(i).end")
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { editor.draft.pauses.remove(at: i) }
                }
            }
            Button {
                editor.draft.addPause()
            } label: {
                Label("Add pause", systemImage: "plus")
            }
            .accessibilityIdentifier("timing.addPause")
        }
    }

    private func hint(_ shown: TimingDraft.ShownSegment) -> String? {
        guard let active = shown.activeMs else { return nil }
        let paused = (shown.pausedMs ?? 0) > 0 ? " (\(DurationFormat.format(shown.pausedMs ?? 0)) paused)" : ""
        return "\(shown.label): \(DurationFormat.format(active))\(paused)"
    }

    /// A time with seconds as text (`2026-10-24 07:15:30`), its error, and a clock-change note or
    /// the segment's live duration.
    private func timeField(_ label: String, text: Binding<String>, path: String, id: String, hint: String? = nil)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.qr(.label))
            TextField("yyyy-mm-dd hh:mm:ss", text: text)
                .font(.qr(.mono))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
            errorText(path)
            if let note = editor.draft.localTimeNote(text.wrappedValue) ?? hint {
                Text(note).font(.qr(.caption)).foregroundStyle(.qr.muted)
            }
        }
    }

    @ViewBuilder private func errorText(_ path: String) -> some View {
        if let error = editor.error(path) {
            Text(error).font(.qr(.footnote)).foregroundStyle(.qr.danger)
                .accessibilityLabel("Error: \(error)")
        }
    }

    // Bindings read the draft now, by index, never a captured value (see `BuilderBindings`).
    private func stepBinding(_ i: Int) -> Binding<String?> {
        Binding(
            get: { editor.draft.segments.indices.contains(i) ? editor.draft.segments[i].step : nil },
            set: { editor.draft.setSegmentStep(i, $0) })
    }

    private func endBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { editor.draft.segments.indices.contains(i) ? editor.draft.segments[i].endedAt : "" },
            set: { if editor.draft.segments.indices.contains(i) { editor.draft.segments[i].endedAt = $0 } })
    }

    private func pauseBinding(_ i: Int, _ path: WritableKeyPath<TimingDraft.Pause, String>) -> Binding<String> {
        Binding(
            get: { editor.draft.pauses.indices.contains(i) ? editor.draft.pauses[i][keyPath: path] : "" },
            set: { if editor.draft.pauses.indices.contains(i) { editor.draft.pauses[i][keyPath: path] = $0 } })
    }
}
