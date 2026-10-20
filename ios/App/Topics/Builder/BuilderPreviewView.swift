import QuickrCore
import QuickrUI
import SwiftUI

/// The live preview (`FormPreview`): the topic's name, then each question as the record screen
/// will show it, answerable, with its validation once the question is left.
struct BuilderPreviewSections<Model: BuilderEditing>: View {
    let model: Model
    /// The topic's name ("Untitled topic" while it has none).
    let title: String
    let id: String

    var body: some View {
        let questions = BuilderPreview.questions(model.draft)
        Section {
            ForEach(Array(zip(model.draft.questions.map(\.id), questions)), id: \.0) { _, question in
                PreviewRow(question: question, preview: model.preview)
            }
        } header: {
            HStack(spacing: 8) {
                Circle().fill(Color.qr.accent).frame(width: 8, height: 8)
                Text("Preview")
                Spacer()
                Text(title.isEmpty ? "Untitled topic" : title)
                    .font(.qr(.label))
                    .textCase(nil)
                    .foregroundStyle(.qr.ink)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(id).preview")
        }
    }
}

/// One question of the preview. Leaving a typed field, or picking a choice, counts as leaving it.
private struct PreviewRow: View {
    let question: Question
    let preview: BuilderPreview
    @FocusState private var focused: Bool

    var body: some View {
        AnswerField(
            question: question,
            input: Binding(
                get: { preview.input(for: question) },
                set: { input in
                    preview.set(input, for: question)
                    if case .choice = question.kind { preview.leave(question) }
                }),
            error: preview.error(for: question), focus: $focused, submitLabel: .done,
            onSubmit: { focused = false }
        )
        .padding(.vertical, 6)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { preview.leave(question) }
        }
    }
}
