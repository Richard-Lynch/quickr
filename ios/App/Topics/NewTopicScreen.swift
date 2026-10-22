import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/new`: create a topic in the bound store (the PWA's `NewTopicPage`). Online only. On success it
/// opens the new topic's record screen in place of this one.
struct NewTopicScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: NewTopicModel?

    var body: some View {
        Group {
            if let model {
                NewTopicView(model: model)
            } else if case .noServer = environment.session?.phase {
                TopicNotice(title: "New topic", heading: "No server yet", text: "Connect to a server first.")
            } else if case .failed(let message) = environment.session?.phase {
                TopicNotice(title: "New topic", heading: "Couldn’t open quickR’s data", text: message)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).qrPaperBackground()
            }
        }
        .task(id: environment.session?.binding) {
            guard model == nil, let session = environment.session, let binding = session.binding else { return }
            let router = environment.router
            model = NewTopicModel(
                writer: SessionTopicWriter(session: session, binding: binding), toasts: environment.toasts,
                onCreated: { topic in
                    // A single topic (no questions) has no form: back to the list, where its tile's
                    // Log logs it in one tap.
                    if topic.questions.isEmpty, !router.path.isEmpty {
                        router.path.removeLast()
                    } else {
                        router.replaceTop(with: .record(TopicLinkRef(topic: topic)))
                    }
                })
        }
    }
}

extension TopicLinkRef {
    /// The topic's slug as a link (its id if the slug can't be one).
    init(topic: Topic) {
        self = TopicLinkRef(topic.slug) ?? TopicLinkRef(id: topic.id)
    }
}

struct NewTopicView: View {
    @Bindable var model: NewTopicModel
    @State private var confirmingLeave = false
    @State private var pane = BuilderPane.edit
    @QuickrReduceMotion private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            form
                // Like the PWA (`window.scrollTo({ top: 0 })`): an error brings the banner into view.
                .onChange(of: model.visibleBanner) { _, banner in
                    guard banner != nil else { return }
                    // The errors are on the editor's fields: show it.
                    pane = .edit
                    // Next turn: the banner's section exists once the editor is back.
                    Task { withQRAnimation(reduceMotion: reduceMotion) { proxy.scrollTo(Self.bannerId, anchor: .top) } }
                }
        }
    }

    private static let bannerId = "newTopic.banner.section"

    private var form: some View {
        List {
            BuilderPanePicker(pane: $pane, id: "newTopic")
            if pane == .edit {
                if let banner = model.visibleBanner {
                    Section {
                        TopicBanner(text: banner, trigger: model.attempts).accessibilityIdentifier("newTopic.banner")
                        ForEach(model.bannerDetails, id: \.self) { detail in
                            Text("• \(detail)").font(.qr(.footnote)).foregroundStyle(.qr.ink)
                        }
                    }
                    .id(Self.bannerId)
                }
                topicSection
                QuestionsSections(model: model, id: "newTopic")
                scheduleSection
            } else {
                BuilderPreviewSections(model: model, title: model.draft.name, id: "newTopic")
            }
            Section {
                Button {
                    Task { await model.create() }
                } label: {
                    HStack {
                        if model.isCreating { ProgressView().tint(.qr.onAccent) }
                        // The whole width, wrapping rather than clipping at accessibility sizes.
                        Text("Create topic").font(.qr(.label)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .listRowBackground(Color.qr.accentStrong)
                .foregroundStyle(.qr.onAccent)
                .disabled(model.isCreating)
                .accessibilityIdentifier("newTopic.create")
            }
        }
        .listStyle(.insetGrouped)
        .tint(.qr.accentStrong)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .qrPaperBackground()
        .disabled(model.isCreating)
        .navigationTitle("New topic")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.hasUnsavedChanges)
        .toolbar {
            if model.hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmingLeave = true
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("newTopic.back")
                }
            }
        }
        .alert("Discard unsaved changes?", isPresented: $confirmingLeave) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(NewTopicModel.leaveWarning)
        }
    }

    private var scheduleSection: some View {
        Section {
            ScheduleEditorRows(
                draft: $model.schedule, errors: model.scheduleErrors, limits: model.limits,
                preview: model.schedulePreview, id: "newTopic.schedule")
        } header: {
            Text("Schedule · optional")
        }
    }

    private var topicSection: some View {
        Section {
            TopicLabeledField("Name", error: model.draftErrors[.name]) {
                TextField("e.g. Sleep log", text: Binding(get: { model.draft.name }, set: { model.draft.setName($0) }))
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("newTopic.name")
            }
            TopicLabeledField("URL slug", hint: "Lowercase letters, digits and dashes", error: model.draftErrors[.slug])
            {
                TextField("sleep-log", text: Binding(get: { model.draft.slug }, set: { model.draft.setSlug($0) }))
                    .font(.qr(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("URL slug")
                    .accessibilityIdentifier("newTopic.slug")
            }
            TopicLabeledField("Description", optional: true, error: model.draftErrors[.description]) {
                TextField("What is this for?", text: $model.draft.description, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("newTopic.description")
            }
        } header: {
            Text("Topic")
        }
    }
}
