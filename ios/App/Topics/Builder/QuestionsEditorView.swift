import QuickrCore
import QuickrUI
import SwiftUI

/// The builder's two panes on a phone (`TopicBuilder`): the editor, or the live preview.
enum BuilderPane: String, CaseIterable {
    case edit = "Edit"
    case preview = "Preview"
}

/// The Edit / Preview switch over the builder.
struct BuilderPanePicker: View {
    @Binding var pane: BuilderPane
    let id: String

    var body: some View {
        Section {
            // A menu at accessibility sizes (X5).
            QuickrSegmentedPicker("Builder view", selection: $pane) {
                ForEach(BuilderPane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            // The switch shows its value; the title is the accessibility label (it clipped).
            .labelsHidden()
            .accessibilityLabel("Builder view")
            .accessibilityIdentifier("\(id).pane")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

/// The question cards (`QuestionsEditor`): "Questions N" with Expand all / Collapse all, a card
/// per question, the list's own error, and "Add question" with its type picker. `id` prefixes
/// the accessibility identifiers (`newTopic.q0.label`).
struct QuestionsSections<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let id: String
    @State private var addingQuestion = false
    @QuickrReduceMotion private var reduceMotion

    var body: some View {
        // A section per card; the first one's header is the list's ("Questions 2  Expand all").
        ForEach(Array(model.draft.questions.enumerated()), id: \.element.id) { index, question in
            Section {
                QuestionCard(model: model, index: index, id: question.id, prefix: id)
            } header: {
                if index == 0 { listHeader }
            }
        }
        Section {
            Button {
                addingQuestion = true
            } label: {
                Label("Add question", systemImage: "plus")
            }
            .disabled(!model.draft.canAddQuestion(limits: model.limits))
            .accessibilityIdentifier("\(id).addQuestion")
            TopicFieldError(model.draftErrors[.questions])
        }
        .confirmationDialog("Add a question", isPresented: $addingQuestion, titleVisibility: .visible) {
            ForEach(QuestionType.allCases, id: \.self) { type in
                Button(type.builderLabel) { withQRAnimation(reduceMotion: reduceMotion) { model.addQuestion(type) } }
                    .accessibilityIdentifier("\(id).addQuestion.\(type.rawValue)")
            }
        } message: {
            Text("Pick what kind of answer it takes.")
        }
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Questions")
            Text("\(model.draft.questions.count)").font(.qr(.monoCaption))
            Spacer()
            if model.draft.questions.count > 1 {
                let allOpen = model.expansion.allOpen(model.draft.questions)
                Button(QuestionExpansion.toggleAllTitle(allOpen: allOpen)) {
                    withQRAnimation(reduceMotion: reduceMotion) { model.expansion.toggleAll(model.draft.questions) }
                }
                .font(.qr(.label))
                .textCase(nil)
                .accessibilityIdentifier("\(id).toggleAll")
            }
        }
    }
}

/// A question type's chip (`TypeChip`): its short name in the type's series colour.
struct TypeChip: View {
    let type: QuestionType

    private var color: Color {
        switch type {
        case .int: .qr.series(2)
        case .double: .qr.series(3)
        case .str: .qr.series(4)
        case .enum: .qr.series(1)
        }
    }

    var body: some View {
        Text(type.builderShort.uppercased())
            .font(.qr(.monoCaption).weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            // "Whole number", not "INT" (BD7).
            .accessibilityLabel(type.builderLabel)
    }
}

/// One question (`QuestionCard`): a header row that opens and closes it (number, type, label,
/// key while closed, an alert when a field has an error, published or new) with a menu to move
/// or remove it; open, the question's fields. A published question's key and type are fixed.
struct QuestionCard<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let index: Int
    let id: DraftQuestion.ID
    let prefix: String
    @QuickrReduceMotion private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// VoiceOver stays on the question it moved (BD1): the card keeps its identity (by id).
    @AccessibilityFocusState private var headerFocused: Bool

    private var question: DraftQuestion? { model.draft[id] }
    private var tag: String { "\(prefix).q\(index)" }

    private func error(_ field: QuestionField) -> String? { model.draftErrors[.question(index, field)] }

    /// A binding to one of the question's fields (read live, `BuilderBindings`).
    private func binding<Value>(_ path: WritableKeyPath<DraftQuestion, Value>, default value: Value) -> Binding<Value> {
        model.binding(id, path, default: value)
    }

    var body: some View {
        if let question {
            header(question)
            if model.isOpen(id) {
                fields(question)
            }
        }
    }

    private func header(_ question: DraftQuestion) -> some View {
        let hasError = model.draftErrors.hasError(inQuestion: index)
        let isOpen = model.isOpen(id)
        return HStack(spacing: 10) {
            Button {
                withQRAnimation(reduceMotion: reduceMotion) { model.expansion.toggle(id) }
            } label: {
                headerLabel(question, isOpen: isOpen, hasError: hasError)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityFocused($headerFocused)
            // Moving without the menu (BD1); focus stays on this question.
            .accessibilityAction(named: "Move up") { move(to: index - 1) }
            .accessibilityAction(named: "Move down") { move(to: index + 1) }
            .accessibilityIdentifier("\(tag).header")
            Menu {
                Button("Move up", systemImage: "arrow.up") { move(to: index - 1) }
                    .disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") { move(to: index + 1) }
                    .disabled(index == model.draft.questions.count - 1)
                Button("Remove question", systemImage: "trash", role: .destructive) {
                    withQRAnimation(reduceMotion: reduceMotion) { _ = model.draft.removeQuestion(id) }
                }
                .disabled(!model.draft.canRemoveQuestion)
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Question \(index + 1) actions")
            .accessibilityIdentifier("\(tag).menu")
        }
        .listRowBackground(hasError ? Color.qr.dangerSoft : nil)
    }

    /// Number, type, label (and key while closed), the error mark, published or new, the chevron.
    /// At accessibility sizes the label gets its own lines under the rest.
    @ViewBuilder
    private func headerLabel(_ question: DraftQuestion, isOpen: Bool, hasError: Bool) -> some View {
        let number = Text("\(index + 1)").font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
        let title = VStack(alignment: .leading, spacing: 2) {
            Text(question.label.isEmpty ? "Untitled question" : question.label)
                .font(.qr(.label))
                .foregroundStyle(question.label.isEmpty ? Color.qr.muted : .qr.ink)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            if !isOpen {
                Text(question.key.isEmpty ? "—" : question.key)
                    .font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
        let marks = HStack(spacing: 8) {
            if hasError {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.qr.danger)
                    .accessibilityLabel("Has errors")
            }
            QuickrBadge(question.locked ? "published" : "new", tone: question.locked ? .neutral : .accent)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.qr.muted)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .accessibilityHidden(true)
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    number
                    TypeChip(type: question.type)
                    Spacer(minLength: 4)
                    marks
                }
                title
            }
        } else {
            HStack(spacing: 10) {
                number.frame(minWidth: 16)
                TypeChip(type: question.type)
                title
                Spacer(minLength: 4)
                marks
            }
        }
    }

    private func move(to destination: Int) {
        guard model.draft.questions.indices.contains(destination) else { return }
        withQRAnimation(reduceMotion: reduceMotion) { model.draft.moveQuestion(id, to: destination) }
        headerFocused = true
    }

    @ViewBuilder
    private func fields(_ question: DraftQuestion) -> some View {
        TopicLabeledField("Question", error: error(.label)) {
            TextField(
                question.type.builderPlaceholder,
                text: model.labelBinding(id)
            )
            .accessibilityLabel("Question")
            .accessibilityIdentifier("\(tag).label")
        }
        TopicLabeledField("Key", hint: question.keyHint, error: error(.key)) {
            if question.locked {
                Label(question.key, systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.qr(.mono))
                    .foregroundStyle(.qr.muted)
                    .accessibilityIdentifier("\(tag).key")
            } else {
                TextField("Key", text: model.keyBinding(id))
                    .font(.qr(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Key")
                    .accessibilityIdentifier("\(tag).key")
            }
        }
        if question.locked {
            TopicLabeledField("Type", hint: question.typeHint, error: nil) {
                HStack(spacing: 8) {
                    TypeChip(type: question.type)
                    Text(question.type.builderLabel).foregroundStyle(.qr.muted)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // At accessibility sizes the title goes above, so the value has the whole row.
                if typeSize.isAccessibilitySize {
                    Text("Type").font(.qr(.label)).foregroundStyle(.qr.inkSoft).accessibilityHidden(true)
                }
                if typeSize.isAccessibilitySize {
                    // The system menu picker cuts its value short ("Whol…mber"): our own label wraps.
                    Menu {
                        Picker("Type", selection: model.typeBinding(id, default: question.type)) {
                            ForEach(QuestionType.allCases, id: \.self) { Text($0.builderLabel).tag($0) }
                        }
                    } label: {
                        HStack {
                            Text(question.type.builderLabel).font(.qr(.body)).multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                        }
                        .frame(minHeight: QuickrMetrics.tapTarget)
                    }
                    .accessibilityLabel("Type")
                    .accessibilityValue(question.type.builderLabel)
                    .accessibilityIdentifier("\(tag).type")
                } else {
                    Picker(
                        "Type",
                        selection: model.typeBinding(id, default: question.type)
                    ) {
                        ForEach(QuestionType.allCases, id: \.self) { Text($0.builderLabel).tag($0) }
                    }
                    .accessibilityIdentifier("\(tag).type")
                }
                Text(question.typeHint).font(.qr(.footnote)).foregroundStyle(.qr.muted)
            }
        }
        TopicLabeledField("Help text", optional: true, error: error(.helpText)) {
            // No placeholder at accessibility sizes, where it can only be cut off.
            TextField(
                typeSize.isAccessibilitySize ? "" : "Shown under the question", text: binding(\.helpText, default: ""),
                axis: .vertical
            )
            .lineLimit(1...4)
            .accessibilityLabel("Help text")
            .accessibilityIdentifier("\(tag).help")
        }
        Toggle(isOn: binding(\.required, default: false)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Required").fixedSize(horizontal: false, vertical: true)
                Text("Must be answered to save an entry").font(.qr(.footnote)).foregroundStyle(.qr.muted)
            }
        }
        .accessibilityIdentifier("\(tag).required")
        constraints(question)
    }

    @ViewBuilder
    private func constraints(_ question: DraftQuestion) -> some View {
        switch question.type {
        case .int, .double:
            FieldRow {
                numberField("Min", \.min, .min)
                numberField("Max", \.max, .max)
            }
            FieldRow {
                if question.type == .double { numberField("Decimals", \.decimals, .decimals, pad: .numberPad) }
                TopicLabeledField("Unit", optional: true, error: error(.unit)) {
                    TextField("kg, h…", text: binding(\.unit, default: ""))
                        .accessibilityLabel("Unit")
                        .accessibilityIdentifier("\(tag).unit")
                }
            }
        case .str:
            FieldRow {
                numberField("Min length", \.minLength, .minLength, pad: .numberPad)
                numberField("Max length", \.maxLength, .maxLength, pad: .numberPad)
            }
            Toggle(isOn: binding(\.multiline, default: false)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multiline").fixedSize(horizontal: false, vertical: true)
                    Text("Show a text area instead of a single line").font(.qr(.footnote)).foregroundStyle(.qr.muted)
                }
            }
            .accessibilityIdentifier("\(tag).multiline")
        case .enum:
            OptionsRows(model: model, index: index, id: id, tag: tag)
            Toggle(
                isOn: model.multipleBinding(id)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow multiple selections").fixedSize(horizontal: false, vertical: true)
                    Text(question.multipleHint).font(.qr(.footnote)).foregroundStyle(.qr.muted)
                }
            }
            .disabled(!question.canToggleMultiple)
            .accessibilityIdentifier("\(tag).multiple")
            TopicFieldError(error(.multiple))
            if question.multiple {
                FieldRow {
                    numberField("Min selections", \.minSelected, .minSelected, pad: .numberPad)
                    numberField("Max selections", \.maxSelected, .maxSelected, pad: .numberPad)
                }
            }
        }
    }

    private func numberField(
        _ label: String, _ path: WritableKeyPath<DraftQuestion, String>, _ field: QuestionField,
        pad: UIKeyboardType = .numbersAndPunctuation
    ) -> some View {
        TopicLabeledField(label, error: error(field)) {
            TextField("—", text: binding(path, default: ""))
                .font(.qr(.mono))
                .keyboardType(pad)
                .accessibilityLabel(label)
                .accessibilityIdentifier("\(tag).\(field.path)")
        }
    }
}

/// A choice question's options (`OptionsEditor`): each one's label and value (the value follows
/// the label until edited), moved with its menu. A published option's value is fixed and it can
/// only be archived (old answers keep it); a new one can be deleted. "Add an option…" adds one.
struct OptionsRows<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let index: Int
    let id: DraftQuestion.ID
    let tag: String
    @Environment(\.dynamicTypeSize) private var typeSize

    private var question: DraftQuestion? { model.draft[id] }

    var body: some View {
        if let question {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow(alignment: .firstTextBaseline) {
                    Text("Options").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Text("≤ 6 show as chips (multi-select: always)").font(.qr(.caption)).foregroundStyle(.qr.muted)
                }
                ForEach(Array(question.options.enumerated()), id: \.element.id) { o, option in
                    row(question, o, option)
                }
                // Stacked at accessibility sizes, where "Add" broke over two lines.
                FieldRow(alignment: .center) {
                    TextField("Add an option…", text: newLabel)
                        .onSubmit(add)
                        .submitLabel(.done)
                        .accessibilityLabel("New option label")
                        .accessibilityIdentifier("\(tag).newOption")
                    Button("Add", systemImage: "plus", action: add)
                        .buttonStyle(.borderless)
                        .disabled(JSNumber.trim(newLabel.wrappedValue).isEmpty)
                        .accessibilityIdentifier("\(tag).addOption")
                }
                TopicFieldError(model.draftErrors[.question(index, .options)])
            }
        }
    }

    private func row(_ question: DraftQuestion, _ o: Int, _ option: DraftOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // At accessibility sizes the buttons go under the label (BD4).
            if typeSize.isAccessibilitySize {
                labelField(o, option)
                HStack(spacing: 8) { optionButtons(question, o, option) }
            } else {
                HStack(spacing: 8) {
                    labelField(o, option)
                    optionButtons(question, o, option)
                }
            }
            FieldRow(alignment: .center) {
                Text("value").font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                if option.locked {
                    Text(option.value).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                    QuickrBadge("published")
                } else {
                    TextField(
                        "value",
                        text: model.optionValueBinding(id, option: option.id)
                    )
                    .font(.qr(.monoCaption))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Option \(o + 1) value")
                    .accessibilityIdentifier("\(tag).option\(o).value")
                }
            }
            TopicFieldError(model.draftErrors[.question(index, .optionLabel(o))])
            TopicFieldError(model.draftErrors[.question(index, .optionValue(o))])
        }
        .opacity(option.archived ? 0.6 : 1)
        .padding(.vertical, 2)
    }

    private func labelField(_ o: Int, _ option: DraftOption) -> some View {
        TextField("Option \(o + 1)", text: model.optionLabelBinding(id, option: option.id))
            .strikethrough(option.archived)
            // Not only struck through (BD3).
            .accessibilityLabel(option.archived ? "Option \(o + 1) label, archived" : "Option \(o + 1) label")
            .accessibilityIdentifier("\(tag).option\(o)")
    }

    /// Archive or Restore (published) or Delete (new), and the move menu, each at least 44 pt (BD2).
    @ViewBuilder
    private func optionButtons(_ question: DraftQuestion, _ o: Int, _ option: DraftOption) -> some View {
        if option.locked {
            Button(option.archived ? "Restore" : "Archive") {
                model.draft.setOptionArchived(id, option: option.id, !option.archived)
            }
            .font(.qr(.label))
            .buttonStyle(.borderless)
            .frame(minHeight: QuickrMetrics.tapTarget)
            .accessibilityIdentifier("\(tag).option\(o).archive")
        } else {
            Button {
                _ = model.draft.removeOption(id, option: option.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.qr.danger)
                    .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete option \(o + 1)")
            .accessibilityIdentifier("\(tag).option\(o).delete")
        }
        Menu {
            Button("Move up", systemImage: "arrow.up") { model.draft.moveOption(id, option: option.id, to: o - 1) }
                .disabled(o == 0)
            Button("Move down", systemImage: "arrow.down") {
                model.draft.moveOption(id, option: option.id, to: o + 1)
            }
            .disabled(o == question.options.count - 1)
        } label: {
            Image(systemName: "arrow.up.arrow.down").foregroundStyle(.qr.muted)
                .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Move option \(o + 1)")
        .accessibilityIdentifier("\(tag).option\(o).move")
    }

    /// The typed option label, kept by the model (it survives the panes and a closed card).
    private var newLabel: Binding<String> { model.newOptionBinding(id) }

    private func add() { model.addPendingOption(to: id) }
}

/// Fields side by side, stacked at accessibility sizes (BD4).
struct FieldRow<Content: View>: View {
    var alignment: VerticalAlignment = .top
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { content }
        } else {
            HStack(alignment: alignment) { content }
        }
    }
}
