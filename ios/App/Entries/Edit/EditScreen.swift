import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/t/:ref/entries/:id` (the PWA's `EntryEditPage`): finds the topic, the entry as the store shows
/// it and the questions of the version it was logged with, then shows `EditView`. The store and its
/// binding are taken together, so the save and the delete act in the store the entry came from.
struct EditScreen: View {
    let ref: TopicLinkRef
    let entryId: UUID
    @Environment(AppEnvironment.self) private var environment
    @State private var load = Load.loading

    private enum Load {
        case loading
        case ready(EditModel, EntriesModel.Row)
        /// A create the server refused: it is fixed on the record screen.
        case refused
        case gone
        case missingTopic
        case failed(String)
    }

    var body: some View {
        content
            .task(id: environment.session?.binding) { if case .loading = load { await start() } }
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .qrPaperBackground()
                .navigationTitle("Edit entry")
        case .ready(let model, let row):
            EditView(model: model, row: row)
        case .refused:
            EditNotice(
                heading: "This entry was not saved",
                text: "The server refused it. Fix it on the record screen, or discard it from the sync list.",
                tone: .danger, id: "edit.refused"
            ) {
                PrimaryButton("Fix it", icon: .edit, size: .medium) {
                    environment.router.replaceTop(with: .record(ref, fix: entryId.wireString))
                }
                .accessibilityIdentifier("edit.fix")
            }
        case .gone:
            EditNotice(
                heading: "This entry was deleted", text: "It may have been deleted here or on another device.",
                tone: .warn, id: "edit.gone")
        case .missingTopic:
            EditNotice(heading: "Topic not found", text: "It may have been deleted.", tone: .warn, id: "edit.missing")
        case .failed(let message):
            EditNotice(heading: "Could not load this entry", text: message, tone: .danger, id: "edit.failed")
        }
    }

    private func start() async {
        guard let session = environment.session, let store = session.store, let binding = session.binding else {
            switch environment.session?.phase {
            case .noServer: load = .failed("Connect to a server first.")
            case .failed(let message): load = .failed(message)
            default: break  // still starting: wait for the binding
            }
            return
        }
        do {
            let topic: ViewTopic? =
                if let id = ref.id { try await store.topics.topic(id: id) } else {
                    try await store.topics.topic(slug: ref.rawValue)
                }
            guard let topic else {
                load = .missingTopic
                return
            }
            guard let viewEntry = try await store.entries.entry(id: entryId), viewEntry.entry.topicId == topic.id
            else {
                load = .gone
                return
            }
            if viewEntry.isLocalOnly, case .failed = viewEntry.syncState {
                load = .refused
                return
            }
            // The entry's own version's questions. The current version's are the topic's, even before
            // its version row has synced.
            let stored = try await store.versions.version(topicId: topic.topic.id, number: viewEntry.entry.version)
            let questions =
                stored?.questions
                ?? (viewEntry.entry.version == topic.topic.currentVersion ? topic.topic.questions : nil)
            guard let questions else {
                load = .failed("Its topic version could not be found.")
                return
            }
            // A refused edit: fixed here, with its errors on the fields (outbox.md §11).
            var fix: EditFix?
            var problem: String?
            if case .failed = viewEntry.syncState {
                let refused = try await store.outbox.items(topicId: topic.topic.id.wireString)
                    .filter { $0.entityId == entryId.wireString && $0.kind == .entryUpdate && $0.state == .failed }
                    .last
                if let draft = refused?.entryUpdateFixDraft(questions: questions) {
                    fix = EditFix(
                        itemId: draft.itemId, rowVersion: draft.rowVersion,
                        patch: EntryPatch(
                            answers: draft.answers, capturedAt: draft.capturedAt, notes: draft.notes,
                            source: draft.source),
                        problem: draft.problem, message: draft.message)
                } else {
                    problem = viewEntry.lastError?.message ?? "The last change didn’t sync."
                }
            }
            let model = EditModel(
                topic: topic.topic, entry: viewEntry.entry, questions: questions,
                localOnly: viewEntry.isLocalOnly, syncProblem: problem, fix: fix, writer: environment.entryWriter,
                toasts: environment.entryToasts, scope: binding.scope)
            load = .ready(model, EntriesModel.Row(entry: viewEntry, binding: binding))
        } catch {
            load = .failed(String(describing: error))
        }
    }
}

/// The edit form: a line about the entry, banners (an older version, a change that didn't sync,
/// a refused save), the answers, Details, and Save changes with Delete beside it. Leaving with
/// unsaved changes asks first.
struct EditView: View {
    @Bindable var model: EditModel
    let row: EntriesModel.Row
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLeave = false

    var body: some View {
        FormView(model: model.form) {
            EntryDetailsSection(model: model, idPrefix: "edit")
            deleteSection
        }
        .disabled(model.isSaving || model.isDeleted)
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        // Save: a sticky bar, or in the keyboard's toolbar while it is up (FORM's shared bar).
        .formSaveBar(
            model.isFixing ? "Save again" : "Save changes", identifier: "edit.save",
            isSaving: model.isSaving,
            onBarHeight: { environment.toastBottomInset = $0 + 8 }, save: save
        )
        .qrPaperBackground()
        .navigationTitle("Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        // One guarded back button the whole time (as on the record screen); the swipes back and
        // VoiceOver's escape go back only while there is nothing to lose.
        .navigationBarBackButtonHidden()
        .background(SwipeBack(isEnabled: !model.hasUnsavedChanges))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: leave) {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("edit.back")
            }
        }
        .accessibilityAction(.escape, leave)
        .alert("Discard your changes?", isPresented: $confirmingLeave) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your changes to this entry haven’t been saved.")
        }
        .onDisappear { environment.toastBottomInset = 8 }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            EntryLine(entry: model.entry)
            if model.isFixing {
                Banner(
                    title: "This change was not saved",
                    text: model.fixMessage.map {
                        "The server said: \($0). Correct it and save again, or discard it from the sync list."
                    } ?? "The server refused it. Correct it and save again, or discard it from the sync list.",
                    tone: .info
                )
                .accessibilityIdentifier("edit.fixBanner")
            }
            if let message = model.errorMessage {
                Banner(
                    title: model.isDeleted ? message : "Not saved", text: model.isDeleted ? nil : message, tone: .danger
                )
                .accessibilityIdentifier("edit.error")
            } else if let problem = model.syncProblem {
                Banner(title: "The last change didn’t sync", text: problem, tone: .warn)
                    .accessibilityIdentifier("edit.syncProblem")
            }
            if model.isOutdated {
                Banner(
                    title: "Logged against version \(model.entry.version)",
                    text: "Validated with that version’s questions so historic answers stay consistent.", tone: .info
                )
                .accessibilityIdentifier("edit.outdated")
            }
        }
    }

    /// Delete, at the end of the form in a section of its own (the iOS edit-screen pattern; the
    /// PWA has it beside Save). No confirm: the entry goes now and an Undo toast holds the delete
    /// back (the PWA's flow).
    private var deleteSection: some View {
        Button(role: .destructive) {
            dismiss()
            let deleter = EntryDeleter(environment: environment)
            let row = row
            Task { await deleter.delete(row) }
        } label: {
            Label("Delete Entry", systemImage: "trash")
                .font(.qr(.callout))
                .frame(maxWidth: .infinity, minHeight: QuickrMetrics.tapTarget)
        }
        .buttonStyle(.qr(.quietDanger, size: .large))
        .padding(.vertical, 4)
        .qrCard()
        .padding(.top, 8)
        .accessibilityLabel("Delete entry")
        .accessibilityIdentifier("edit.delete")
    }

    private func save() {
        Task {
            if await model.save() == .leave { dismiss() }
        }
    }

    /// Back: straight away when nothing changed, else asks first.
    private func leave() {
        if model.hasUnsavedChanges { confirmingLeave = true } else { dismiss() }
    }
}

/// "v2 · iOS · logged 12 Oct 2026 at 08:00".
private struct EntryLine: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 6) {
            QuickrBadge("v\(entry.version)")
            if entry.channel != .ui { QuickrBadge(channel, tone: entry.channel == .ios ? .info : .neutral) }
            Text("logged \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.qr.paper)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("edit.entryLine")
    }

    private var channel: String {
        switch entry.channel {
        case .ui: "Web"
        case .api: "API"
        case .mcp: "MCP"
        case .ios: "iOS"
        }
    }
}

private struct Banner: View {
    let title: String
    let text: String?
    let tone: QuickrTone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.qr(.callout))
            if let text { Text(text).font(.qr(.subheadline)).fixedSize(horizontal: false, vertical: true) }
        }
        .foregroundStyle(tone.foreground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background)
        .accessibilityElement(children: .combine)
    }
}

private struct EditNotice<Action: View>: View {
    let heading: String
    let text: String
    let tone: QuickrTone
    let id: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 12) {
            Text(heading).font(.qr(.title)).foregroundStyle(tone.foreground).multilineTextAlignment(.center)
            Text(text)
                .font(.qr(.body))
                .foregroundStyle(.qr.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qrPaperBackground()
        .navigationTitle("Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

extension EditNotice where Action == EmptyView {
    init(heading: String, text: String, tone: QuickrTone, id: String) {
        self.init(heading: heading, text: text, tone: tone, id: id) { EmptyView() }
    }
}
