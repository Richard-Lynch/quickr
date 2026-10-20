import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/t/:ref/record[?fix=<item id>]`: finds the topic, its latest entry (for "Same as last time")
/// or the rejected entry to fix, then shows `RecordView`. An archived topic, a missing one, or a
/// fix that is no longer there each say so (the PWA's `RecordPage`).
struct RecordScreen: View {
    let ref: TopicLinkRef
    let fix: String?
    @Environment(AppEnvironment.self) private var environment
    @State private var load = Load.loading

    private enum Load {
        case loading
        case ready(RecordModel)
        case archived(Topic)
        case nothingToFix(Topic)
        case missing
        case failed(String)
    }

    var body: some View {
        content
            // A link can open this before the store is bound (at launch): it loads once it is.
            .task(id: environment.session?.binding) { if case .loading = load { await start() } }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .qrPaperBackground()
        case .ready(let model):
            RecordView(model: model, settings: environment.settings)
        case .archived(let topic):
            Notice(
                title: topic.name, heading: "This topic is archived", text: "Unarchive it to log new entries.",
                tone: .warn)
        case .nothingToFix(let topic):
            Notice(
                title: "Fix entry · \(topic.name)", heading: "Nothing to fix",
                text: "This entry has already been synced or discarded.", tone: .info)
        case .missing:
            Notice(title: "Record", heading: "Topic not found", text: "It may have been deleted.", tone: .warn)
        case .failed(let message):
            Notice(title: "Record", heading: "Couldn’t open this topic", text: message, tone: .danger)
        }
    }

    private func start() async {
        guard let session = environment.session, let store = session.store else {
            switch environment.session?.phase {
            case .noServer: load = .failed("Connect to a server first.")
            case .failed(let message): load = .failed(message)
            default: break  // still starting: wait for the binding
            }
            return
        }
        do {
            let view =
                if let id = ref.id {
                    try await store.topics.topic(id: id)
                } else {
                    try await store.topics.topic(slug: ref.rawValue)
                }
            guard let topic = view?.topic else {
                load = .missing
                return
            }
            guard topic.status != .archived else {
                load = .archived(topic)
                return
            }
            let mode: RecordModel.Mode
            if let fix {
                guard let draft = try await store.outbox.item(id: fix)?.entryFixDraft(questions: topic.questions),
                    draft.topic.id == topic.id.wireString
                else {
                    load = .nothingToFix(topic)
                    return
                }
                mode = .fix(
                    RecordFix(
                        itemId: draft.itemId, rowVersion: draft.rowVersion, answers: draft.answers,
                        capturedAt: draft.capturedAt, notes: draft.notes, problem: draft.problem,
                        message: draft.message))
            } else {
                let last = try await store.entries.latestEntry(topicId: topic.id)
                mode = .new(last: last.map { LastEntry($0.entry) })
            }
            load = .ready(
                RecordModel(
                    topic: topic, mode: mode, writer: RecordSessionWriter(session: session),
                    notices: RecordToasts(center: environment.toasts, session: session),
                    logAnother: environment.settings.logAnother))
        } catch {
            load = .failed(String(describing: error))
        }
    }
}

/// A screen that can't record, saying why.
private struct Notice: View {
    let title: String
    let heading: String
    let text: String
    let tone: QuickrTone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.qr(.callout))
            Text(text).font(.qr(.subheadline))
        }
        .foregroundStyle(tone.foreground)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: QuickrMetrics.chipRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record.notice")
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .qrPaperBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
