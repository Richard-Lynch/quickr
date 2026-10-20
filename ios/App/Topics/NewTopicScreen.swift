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
                    router.replaceTop(with: .record(TopicLinkRef(topic: topic)))
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
    @State private var addingQuestion = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let banner = model.visibleBanner {
                Section {
                    Banner(text: banner).accessibilityIdentifier("newTopic.banner")
                    ForEach(model.bannerDetails, id: \.self) { detail in
                        Text("• \(detail)").font(.qr(.footnote)).foregroundStyle(.qr.ink)
                    }
                }
            }
            topicSection
            ForEach(Array(model.draft.questions.enumerated()), id: \.element.id) { index, question in
                QuestionCard(model: model, index: index, id: question.id)
            }
            Section {
                Button {
                    addingQuestion = true
                } label: {
                    Label("Add question", systemImage: "plus")
                }
                .disabled(!model.draft.canAddQuestion(limits: model.limits))
                .accessibilityIdentifier("newTopic.addQuestion")
                FieldError(model.draftErrors[.questions])
            }
            Section {
                ScheduleEditorRows(
                    draft: $model.schedule, errors: model.scheduleErrors, limits: model.limits,
                    preview: model.schedulePreview, id: "newTopic.schedule")
            } header: {
                Text("Schedule · optional")
            }
            Section {
                Button {
                    Task { await model.create() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isCreating { ProgressView().tint(.qr.onAccent) }
                        Label("Create topic", systemImage: "checkmark").font(.qr(.label))
                        Spacer()
                    }
                    .frame(minHeight: 44)
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
        .confirmationDialog("Add a question", isPresented: $addingQuestion, titleVisibility: .visible) {
            ForEach(QuestionType.allCases, id: \.self) { type in
                Button(type.builderLabel) { _ = model.draft.addQuestion(type) }
                    .accessibilityIdentifier("newTopic.addQuestion.\(type.rawValue)")
            }
        } message: {
            Text("Pick what kind of answer it takes.")
        }
    }

    private var topicSection: some View {
        Section {
            LabeledField("Name", error: model.draftErrors[.name]) {
                TextField("e.g. Sleep log", text: Binding(get: { model.draft.name }, set: { model.draft.setName($0) }))
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("newTopic.name")
            }
            LabeledField("URL slug", hint: "Lowercase letters, digits and dashes", error: model.draftErrors[.slug]) {
                TextField("sleep-log", text: Binding(get: { model.draft.slug }, set: { model.draft.setSlug($0) }))
                    .font(.qr(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("URL slug")
                    .accessibilityIdentifier("newTopic.slug")
            }
            LabeledField("Description", optional: true, error: model.draftErrors[.description]) {
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

/// One question being created: its type, label, key, help text, required, and the type's
/// constraints or options. BUILDER-UI extends these cards (preview, versions, compatibility).
struct QuestionCard: View {
    @Bindable var model: NewTopicModel
    let index: Int
    let id: DraftQuestion.ID

    private var question: DraftQuestion? { model.draft.questions.first { $0.id == id } }

    private func error(_ field: QuestionField) -> String? { model.draftErrors[.question(index, field)] }

    /// A binding to one of the question's text fields.
    private func text(_ path: WritableKeyPath<DraftQuestion, String>) -> Binding<String> {
        Binding(
            get: { question?[keyPath: path] ?? "" },
            set: { value in
                guard let i = model.draft.index(of: id) else { return }
                model.draft.questions[i][keyPath: path] = value
            })
    }

    private func flag(_ path: WritableKeyPath<DraftQuestion, Bool>) -> Binding<Bool> {
        Binding(
            get: { question?[keyPath: path] ?? false },
            set: { value in
                guard let i = model.draft.index(of: id) else { return }
                model.draft.questions[i][keyPath: path] = value
            })
    }

    var body: some View {
        if let question {
            Section {
                Picker(
                    "Type",
                    selection: Binding(
                        get: { question.type }, set: { _ = model.draft.setType(id, to: $0) })
                ) {
                    ForEach(QuestionType.allCases, id: \.self) { Text($0.builderLabel).tag($0) }
                }
                .accessibilityIdentifier("newTopic.q\(index).type")
                LabeledField("Question", error: error(.label)) {
                    TextField("Question", text: Binding(get: { question.label }, set: { model.draft.setLabel(id, $0) }))
                        .accessibilityIdentifier("newTopic.q\(index).label")
                }
                LabeledField("Key", error: error(.key)) {
                    TextField("Key", text: Binding(get: { question.key }, set: { _ = model.draft.setKey(id, $0) }))
                        .font(.qr(.mono))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("newTopic.q\(index).key")
                }
                LabeledField("Help text", optional: true, error: error(.helpText)) {
                    TextField("Shown under the question", text: text(\.helpText))
                        .accessibilityIdentifier("newTopic.q\(index).help")
                }
                Toggle(isOn: flag(\.required)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Required")
                        Text("Must be answered to save an entry").font(.qr(.footnote)).foregroundStyle(.qr.muted)
                    }
                }
                .accessibilityIdentifier("newTopic.q\(index).required")
                constraints(question)
                actions
            } header: {
                Text("Question \(index + 1) · \(question.type.builderLabel)")
            }
        }
    }

    @ViewBuilder
    private func constraints(_ question: DraftQuestion) -> some View {
        switch question.type {
        case .int, .double:
            HStack(alignment: .top) {
                LabeledField("Min", error: error(.min)) {
                    TextField("—", text: text(\.min)).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("newTopic.q\(index).min")
                }
                LabeledField("Max", error: error(.max)) {
                    TextField("—", text: text(\.max)).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("newTopic.q\(index).max")
                }
            }
            HStack(alignment: .top) {
                LabeledField("Unit", error: error(.unit)) {
                    TextField("kg, h…", text: text(\.unit)).accessibilityIdentifier("newTopic.q\(index).unit")
                }
                if question.type == .double {
                    LabeledField("Decimals", error: error(.decimals)) {
                        TextField("—", text: text(\.decimals)).keyboardType(.numberPad)
                            .accessibilityIdentifier("newTopic.q\(index).decimals")
                    }
                }
            }
        case .str:
            HStack(alignment: .top) {
                LabeledField("Min length", error: error(.minLength)) {
                    TextField("0", text: text(\.minLength)).keyboardType(.numberPad)
                        .accessibilityIdentifier("newTopic.q\(index).minLength")
                }
                LabeledField("Max length", error: error(.maxLength)) {
                    TextField("—", text: text(\.maxLength)).keyboardType(.numberPad)
                        .accessibilityIdentifier("newTopic.q\(index).maxLength")
                }
            }
            Toggle(isOn: flag(\.multiline)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multiline")
                    Text("Show a text area instead of a single line").font(.qr(.footnote)).foregroundStyle(.qr.muted)
                }
            }
            .accessibilityIdentifier("newTopic.q\(index).multiline")
        case .enum:
            OptionsRows(model: model, index: index, id: id)
            Toggle(
                "Allow multiple selections",
                isOn: Binding(get: { question.multiple }, set: { _ = model.draft.setMultiple(id, $0) })
            )
            .accessibilityIdentifier("newTopic.q\(index).multiple")
            if question.multiple {
                HStack(alignment: .top) {
                    LabeledField("Min selections", error: error(.minSelected)) {
                        TextField("—", text: text(\.minSelected)).keyboardType(.numberPad)
                            .accessibilityIdentifier("newTopic.q\(index).minSelected")
                    }
                    LabeledField("Max selections", error: error(.maxSelected)) {
                        TextField("—", text: text(\.maxSelected)).keyboardType(.numberPad)
                            .accessibilityIdentifier("newTopic.q\(index).maxSelected")
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                model.draft.moveQuestion(id, to: index - 1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("Move up")
            Button {
                model.draft.moveQuestion(id, to: index + 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == model.draft.questions.count - 1)
            .accessibilityLabel("Move down")
            Spacer()
            Button(role: .destructive) {
                _ = model.draft.removeQuestion(id)
            } label: {
                Label("Remove question", systemImage: "trash")
            }
            .disabled(!model.draft.canRemoveQuestion)
            .accessibilityIdentifier("newTopic.q\(index).remove")
        }
        .buttonStyle(.borderless)
    }
}

/// A choice question's options: each label (its value follows it), remove, and "Add an option…".
struct OptionsRows: View {
    @Bindable var model: NewTopicModel
    let index: Int
    let id: DraftQuestion.ID
    @State private var newLabel = ""

    private var question: DraftQuestion? { model.draft.questions.first { $0.id == id } }

    var body: some View {
        if let question {
            VStack(alignment: .leading, spacing: 6) {
                Text("Options").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                ForEach(Array(question.options.enumerated()), id: \.element.id) { o, option in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            TextField(
                                "Option \(o + 1)",
                                text: Binding(
                                    get: { option.label },
                                    set: { model.draft.setOptionLabel(id, option: option.id, $0) })
                            )
                            .accessibilityIdentifier("newTopic.q\(index).option\(o)")
                            Text(option.value).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                            Button {
                                _ = model.draft.removeOption(id, option: option.id)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.qr.muted)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove option \(option.label)")
                        }
                        FieldError(model.draftErrors[.question(index, .optionLabel(o))])
                        FieldError(model.draftErrors[.question(index, .optionValue(o))])
                    }
                }
                HStack {
                    TextField("Add an option…", text: $newLabel)
                        .onSubmit(add)
                        .accessibilityLabel("New option label")
                        .accessibilityIdentifier("newTopic.q\(index).newOption")
                    Button("Add", action: add).buttonStyle(.borderless).disabled(newLabel.isEmpty)
                }
                FieldError(model.draftErrors[.question(index, .options)])
            }
        }
    }

    private func add() {
        let label = newLabel
        guard !label.isEmpty else { return }
        _ = model.draft.addOption(to: id, label: label)
        newLabel = ""
    }
}
