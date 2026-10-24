import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/t/:ref/record?finish=<run>[&fix=<item>]`: the answers form of a run that Stop ended, or of a
/// refused finish to fix (timers.md §11.2, §3.6). It shows the questions of the run's own version
/// (from the local run, or its entry once the run has closed) and notes; Save sends `finish`.
/// Leaving keeps a finishing run as "Add details" on home. No Discard here: the run is stopped.
struct RunDetailsScreen: View {
    let ref: TopicLinkRef
    let runId: UUID
    let fix: String?
    @Environment(AppEnvironment.self) private var environment
    @State private var load = Load.loading

    private enum Load {
        case loading
        case ready(RunDetailsModel)
        case unavailable(String)
    }

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).qrPaperBackground()
            case .ready(let model):
                RunDetailsView(model: model)
            case .unavailable(let message):
                Text(message)
                    .font(.qr(.body))
                    .foregroundStyle(.qr.muted)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .qrPaperBackground()
                    .navigationTitle("Details")
                    .accessibilityIdentifier("runDetails.unavailable")
            }
        }
        .task(id: environment.session?.binding) { if case .loading = load { await start() } }
    }

    private func start() async {
        guard let session = environment.session, let store = session.store else { return }
        do {
            let topic: Topic? =
                if let id = ref.id { try await store.topics.topic(id: id)?.topic } else {
                    try await store.topics.topic(slug: ref.rawValue)?.topic
                }
            guard let topic else {
                load = .unavailable("Topic not found. It may have been deleted.")
                return
            }
            // The run's own version: from the local run, else from the entry it became.
            let run = try await store.runs.localRun(id: runId)
            let entry = try await store.entries.entry(id: runId)
            guard let version = run?.version ?? entry?.entry.version else {
                load = .unavailable("This run is no longer on this iPhone.")
                return
            }
            let questions: [Question]? =
                if let stored = try await store.versions.version(topicId: topic.id, number: version) {
                    stored.questions
                } else {
                    version == topic.currentVersion ? topic.questions : nil
                }
            guard let questions else {
                load = .unavailable("This run’s questions haven’t synced to this iPhone yet. Try again in a moment.")
                return
            }
            var draft: RunDetailsFix?
            if let fix {
                guard let found = try await store.outbox.item(id: fix)?.runFixDraft(questions: questions) else {
                    load = .unavailable("Nothing to fix: these details have already been synced or discarded.")
                    return
                }
                draft = RunDetailsFix(
                    itemId: found.itemId, answers: found.answers, notes: found.notes, problem: found.problem,
                    message: found.message)
            }
            load = .ready(
                RunDetailsModel(
                    topicName: topic.name, runId: runId.wireString, questions: questions, fix: draft,
                    finisher: SessionRunFinisher(session: session)))
        } catch {
            load = .unavailable(String(describing: error))
        }
    }
}

private struct RunDetailsView: View {
    @Bindable var model: RunDetailsModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLeave = false

    var body: some View {
        FormView(model: model.form) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                TextField("", text: $model.notes, axis: .vertical)
                    .font(.qr(.body))
                    .lineLimit(2...6)
                    .padding(12)
                    .background(Color.qr.surface, in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius).strokeBorder(Color.qr.line)
                    }
                    .accessibilityLabel("Notes")
                    .accessibilityIdentifier("runDetails.notes")
            }
            .padding(.horizontal, 4)
        }
        .disabled(model.isSaving)
        .safeAreaInset(edge: .top) {
            if let banner = model.banner {
                Text(banner)
                    .font(.qr(.subheadline))
                    .foregroundStyle(QuickrTone.danger.foreground)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(QuickrTone.danger.background)
                    .accessibilityIdentifier("runDetails.banner")
            }
        }
        .formSaveBar(
            model.isFixing ? "Save again" : "Save", identifier: "runDetails.save", isSaving: model.isSaving,
            onBarHeight: { environment.toastBottomInset = $0 + 8 }
        ) {
            Task {
                guard await model.save() == .leave else { return }
                if let message = model.savedMessage { environment.toasts.show(Toast(message)) }
                dismiss()
            }
        }
        .qrPaperBackground()
        .navigationTitle("Details · \(model.topicName)")
        .navigationBarTitleDisplayMode(.inline)
        // As on the record screen: the system back while nothing is typed; once something is, a
        // guarded back that asks first. The run stays "Add details" either way.
        .navigationBarBackButtonHidden(model.hasUnsavedChanges)
        .toolbar {
            if model.hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: leave) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("runDetails.back")
                }
            }
        }
        .accessibilityAction(.escape, leave)
        .alert("Leave without saving?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your answers haven’t been saved. The run stays on home as “Add details”.")
        }
        .onDisappear { environment.toastBottomInset = 8 }
    }
}

extension RunDetailsView {
    /// Back: straight away when nothing was typed, else asks first.
    fileprivate func leave() {
        if model.hasUnsavedChanges { confirmingLeave = true } else { dismiss() }
    }
}

/// `RunFinishing` over the app's session: `finish` through the run façade, then the record
/// screen's short wait for the server (outbox.md §10). A new finish that is refused is dropped,
/// as a refused new entry is, so the errors live on the form only; a fix keeps its item for the
/// sync sheet.
struct SessionRunFinisher: RunFinishing {
    let session: AppSession

    func finish(runId: String, answers: [String: AnswerValue], notes: String?) async -> RunFinishDelivery {
        let result: OutboxEnqueueResult?
        do {
            result = try await session.tapRun(.finish, runId: runId, answers: answers, notes: notes)
        } catch {
            return .notSaved(String(describing: error))
        }
        guard case .appended(let item) = result else {
            return .notSaved("This run is no longer on this iPhone, so its details can’t be saved.")
        }
        let delivery = await send(item.id)
        switch delivery {
        case .failed, .runOpen:
            try? await session.outbox?.discard(itemId: item.id, origin: .app)
        default:
            break
        }
        return delivery
    }

    func refix(itemId: String, answers: [String: AnswerValue], notes: String?) async -> RunFinishDelivery {
        guard let outbox = await session.outbox, let store = await session.store else {
            return .notSaved("The server or its data changed, so this can’t be saved here.")
        }
        do {
            guard let item = try await store.outbox.item(id: itemId) else {
                return .notSaved("These details have already been synced or discarded.")
            }
            try await outbox.fixRunEvent(itemId: itemId, rowVersion: item.rowVersion, answers: answers, notes: notes)
        } catch {
            return .notSaved(String(describing: error))
        }
        return await send(itemId)
    }

    private func send(_ itemId: String) async -> RunFinishDelivery {
        guard let scheduler = await session.scheduler else { return .queued }
        switch await scheduler.sendNow(itemId: itemId, wait: RecordModel.sendWait) {
        case .sent: return .sent
        case .retired: return .notSaved("The topic was deleted, so these details can’t be saved.")
        case .queued: return .queued
        case .failed(let info):
            if info?.problem?.code == .runOpen { return .runOpen }
            return .failed(message: info?.message ?? "The server refused it", problem: info?.problem)
        }
    }
}
