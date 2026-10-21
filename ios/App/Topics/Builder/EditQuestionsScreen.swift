import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/t/:ref/edit`: finds the topic in the bound store and edits its questions into the next
/// version (`EditQuestionsView`). Online only; once published it shows the topic's Versions tab.
struct EditQuestionsScreen: View {
    let ref: TopicLinkRef
    @Environment(AppEnvironment.self) private var environment
    @State private var load = Load.loading

    private enum Load {
        case loading
        case ready(EditQuestionsModel)
        case missing
        case failed(String)
    }

    var body: some View {
        content
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
            EditQuestionsView(model: model)
        case .missing:
            TopicNotice(title: "Edit questions", heading: "Topic not found", text: "It may have been deleted.")
        case .failed(let message):
            TopicNotice(title: "Edit questions", heading: "Couldn’t open this topic", text: message)
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
            guard
                let topic = try await TopicLookup.find(
                    ref, in: store, refresh: session.refresh.stream(), wait: TopicSettingsScreen.topicWait)
            else {
                load = .missing
                return
            }
            let router = environment.router
            let model = EditQuestionsModel(
                topic: topic, writer: SessionTopicWriter(session: session, binding: binding),
                toasts: environment.toasts,
                onPublished: { topic in
                    // To the topic's Versions tab: in place of the topic screen this was opened
                    // from, if it was, so Back doesn't return to the editor.
                    let versions = Route.topic(TopicLinkRef(topic: topic), .versions)
                    var path = router.path
                    if !path.isEmpty { path.removeLast() }
                    if case .topic(let below, _)? = path.last, below.matches(topic) { path.removeLast() }
                    router.path = path + [versions]
                })
            load = .ready(model)
        } catch {
            load = .failed(String(describing: error))
        }
    }
}

/// The editor (`EditQuestionsPage`): what publishing does, the question cards or the preview,
/// and "Review changes"; the review and conflict sheets over it.
struct EditQuestionsView: View {
    @Bindable var model: EditQuestionsModel
    @State private var pane = BuilderPane.edit
    @State private var confirmingLeave = false
    @Environment(\.dismiss) private var dismiss
    @QuickrReduceMotion private var reduceMotion

    private static let bannerId = "editQuestions.banner.section"

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.visibleBanner) { _, banner in
                    guard banner != nil else { return }
                    pane = .edit
                    Task { withQRAnimation(reduceMotion: reduceMotion) { proxy.scrollTo(Self.bannerId, anchor: .top) } }
                }
        }
        .sheet(
            isPresented: Binding(get: { model.review != nil }, set: { if !$0 { model.closeReview() } })
        ) {
            ReviewSheet(model: model)
        }
        .sheet(isPresented: $model.showsConflict) {
            ConflictSheet(model: model)
        }
    }

    private var list: some View {
        List {
            BuilderPanePicker(pane: $pane, id: "editQuestions")
            if pane == .edit {
                Section {
                    Text(
                        "Publishing creates \(Text("v\(model.nextVersion)").bold().foregroundStyle(.qr.ink)) of \(Text(model.base.name).bold().foregroundStyle(.qr.ink)). Published keys and types are fixed; enum options can be archived but not removed. Existing entries keep their original version."
                    )
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                    .accessibilityIdentifier("editQuestions.intro")
                }
                if let banner = model.visibleBanner {
                    Section {
                        TopicBanner(text: banner, trigger: model.attempts).accessibilityIdentifier(
                            "editQuestions.banner")
                        ForEach(model.bannerDetails, id: \.self) { detail in
                            Text("• \(detail)").font(.qr(.footnote)).foregroundStyle(.qr.ink)
                        }
                    }
                    .id(Self.bannerId)
                }
                QuestionsSections(model: model, id: "editQuestions")
            } else {
                BuilderPreviewSections(model: model, title: model.base.name, id: "editQuestions")
            }
            Section {
                Button {
                    Task { await model.reviewChanges() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isChecking { ProgressView().tint(.qr.onAccent) }
                        Label("Review changes", systemImage: "eye").font(.qr(.label))
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Color.qr.accentStrong)
                .foregroundStyle(.qr.onAccent)
                .disabled(model.isChecking)
                .accessibilityIdentifier("editQuestions.review")
            }
        }
        // Nothing changes under a call that is out (Codex r1): its answer is about this draft.
        .disabled(model.isBusy)
        .listStyle(.insetGrouped)
        .tint(.qr.accentStrong)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .qrPaperBackground()
        .navigationTitle("Edit questions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.hasUnsavedChanges)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text("Edit questions").font(.qr(.label))
                    QuickrBadge("v\(model.base.currentVersion)")
                }
                .accessibilityElement(children: .combine)
            }
            if model.hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmingLeave = true
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("editQuestions.back")
                }
            }
        }
        .alert("Discard unsaved changes?", isPresented: $confirmingLeave) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(EditQuestionsModel.leaveWarning)
        }
    }
}

/// "Review changes" (`CompatReport` in a sheet): the report against the base version, the
/// change note when it can be published, "Keep editing" and "Publish v(n+1)".
private struct ReviewSheet: View {
    @Bindable var model: EditQuestionsModel

    var body: some View {
        NavigationStack {
            List {
                if let review = model.review {
                    CompatReportSections(report: review.report, label: model.label(forKey:))
                    if review.report.ok {
                        Section {
                            TopicLabeledField("Change note", optional: true, error: model.noteError) {
                                TextField("What changed and why?", text: $model.draft.changeNote, axis: .vertical)
                                    .lineLimit(2...5)
                                    .accessibilityLabel("Change note")
                                    .accessibilityIdentifier("review.note")
                                    .disabled(model.isPublishing)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .qrPaperBackground()
            .navigationTitle("Review changes")
            .navigationSubtitle("Compared with v\(model.base.currentVersion)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep editing") { model.closeReview() }
                        .disabled(model.isPublishing)
                        .accessibilityIdentifier("review.keepEditing")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.publish() }
                    } label: {
                        if model.isPublishing {
                            ProgressView()
                        } else {
                            Text("Publish v\(model.review?.report.nextVersion ?? model.nextVersion)")
                        }
                    }
                    .disabled(model.review?.report.ok != true || model.isPublishing)
                    .accessibilityIdentifier("review.publish")
                }
            }
            .interactiveDismissDisabled(model.isPublishing)
        }
    }
}

/// A compatibility report (`CompatReport`): whether it can be published, the checks (errors
/// first), then what changed per question.
struct CompatReportSections: View {
    let report: CompatibilityReport
    let label: (String) -> String

    var body: some View {
        Section {
            Label {
                Text(CompatReportText.headline(report)).font(.qr(.label))
            } icon: {
                Image(systemName: report.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            }
            .foregroundStyle(report.ok ? Color.qr.ok : .qr.danger)
            .listRowBackground(report.ok ? Color.qr.okSoft : .qr.dangerSoft)
            // The icon would read as "Selected": the row is its text.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CompatReportText.headline(report))
            .accessibilityIdentifier("review.headline")
        }
        let issues = CompatReportText.sortedIssues(report)
        if !issues.isEmpty {
            Section("Checks") {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    issueRow(issue)
                }
            }
        }
        Section("Changes") {
            if report.changes.isEmpty {
                Text("No changes.").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
            }
            ForEach(Array(report.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        QuickrBadge(CompatReportText.kindLabel(change.kind), tone: tone(change.kind))
                        Text(CompatReportText.subject(change, label: label)).font(.qr(.label)).lineLimit(2)
                    }
                    ForEach(change.details, id: \.self) { detail in
                        Text(detail).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func issueRow(_ issue: CompatibilityReport.Issue) -> some View {
        let (color, soft): (Color, Color) =
            switch issue.level {
            case .error: (.qr.danger, .qr.dangerSoft)
            case .warning: (.qr.warn, .qr.warnSoft)
            case .info: (.qr.info, .qr.infoSoft)
            }
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                if let key = issue.questionKey { Text(label(key)).font(.qr(.label)).foregroundStyle(.qr.ink) }
                Text(issue.message).font(.qr(.subheadline)).foregroundStyle(.qr.inkSoft)
            }
        } icon: {
            Image(systemName: issue.level == .info ? "info.circle" : "exclamationmark.triangle")
                .foregroundStyle(color)
                .accessibilityLabel(CompatReportText.levelLabel(issue.level))
        }
        .listRowBackground(soft)
    }

    private func tone(_ kind: CompatibilityReport.ChangeKind) -> QuickrTone {
        switch kind {
        case .added: .ok
        case .removed: .danger
        case .modified: .info
        case .restored: .accent
        case .reordered: .neutral
        }
    }
}

/// "Someone else published first": keep the draft to copy from, or load the latest version.
private struct ConflictSheet: View {
    let model: EditQuestionsModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("This topic got a new version while you were editing.")
                    .font(.qr(.label))
                    .foregroundStyle(.qr.ink)
                Text(
                    "Your edits were based on v\(model.base.currentVersion). Load the latest version to start again from it (your unsaved edits will be discarded), or keep your draft open to copy anything you need first."
                )
                .font(.qr(.body))
                .foregroundStyle(.qr.inkSoft)
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button {
                        Task { await model.reloadLatest() }
                    } label: {
                        HStack {
                            if model.isReloading { ProgressView() }
                            Text("Load latest version")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isReloading)
                    .accessibilityIdentifier("conflict.reload")
                    Button {
                        model.keepDraft()
                    } label: {
                        Text("Keep my draft").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("conflict.keep")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .qrPaperBackground()
            .navigationTitle("Someone else published first")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isReloading)
    }
}
