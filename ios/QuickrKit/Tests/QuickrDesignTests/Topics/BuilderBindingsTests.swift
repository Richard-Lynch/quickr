import Foundation
import QuickrCore
import QuickrUI
import SwiftUI
import Testing

/// The builder's field bindings read the draft when SwiftUI reads them, not when the view last
/// rendered: under load a field's binding is read between renders, and a value captured at render
/// time handed back the text from before the latest keystrokes ("Glasses of water" typed, "Glasses
/// of w" kept; m1-outbox's d813106 run).
@MainActor @Suite struct BuilderBindingsTests {
    let model: NewTopicModel = {
        let model = NewTopicModel(writer: FakeTopicWriter(server: TopicSettingsModelTests.topic), toasts: ToastCenter())
        model.addQuestion(.int)  // a new topic starts empty: one question to bind to
        return model
    }()

    /// A binding made at "render", then keystrokes reaching the draft before the next render.
    @Test func theLabelReadsLaterKeystrokes() {
        let id = model.draft.questions[0].id
        let label = model.labelBinding(id)
        label.wrappedValue = "Glasses of w"
        model.draft.setLabel(id, "Glasses of water")
        #expect(label.wrappedValue == "Glasses of water")
        // SwiftUI writing back what it read keeps the later keystrokes.
        label.wrappedValue = label.wrappedValue
        #expect(model.draft[id]?.label == "Glasses of water")
        #expect(model.draft[id]?.key == "glasses_of_water", "the key follows the label")
    }

    @Test func everyQuestionFieldReadsTheDraftNow() {
        model.addQuestion(.enum)
        let id = model.draft.questions[1].id
        let key = model.keyBinding(id)
        let help = model.binding(id, \.helpText, default: "")
        let multiple = model.multipleBinding(id)
        let type = model.typeBinding(id, default: .int)
        model.draft.questions[1].helpText = "Pick one"
        _ = model.draft.setKey(id, "mood")
        _ = model.draft.setMultiple(id, true)
        #expect(key.wrappedValue == "mood")
        #expect(help.wrappedValue == "Pick one")
        #expect(multiple.wrappedValue)
        #expect(type.wrappedValue == .enum)
        _ = model.draft.setType(id, to: .str)
        #expect(type.wrappedValue == .str)
    }

    @Test func optionFieldsReadTheDraftNow() {
        model.addQuestion(.enum)
        let id = model.draft.questions[1].id
        let option = model.draft.questions[1].options[0].id
        let label = model.optionLabelBinding(id, option: option)
        let value = model.optionValueBinding(id, option: option)
        model.draft.setOptionLabel(id, option: option, "Absolutely")
        #expect(label.wrappedValue == "Absolutely")
        #expect(value.wrappedValue == model.draft[id]?.options[0].value)
        _ = model.draft.setOptionValue(id, option: option, "abs")
        #expect(value.wrappedValue == "abs")
        // Moved: the binding follows the option, not its old position.
        model.draft.moveOption(id, option: option, to: 1)
        #expect(label.wrappedValue == "Absolutely")
        let pending = model.newOptionBinding(id)
        model.newOptionLabels[id] = "Maybe"
        #expect(pending.wrappedValue == "Maybe")
    }

    @Test func aRemovedQuestionReadsAsBlankAndIgnoresWrites() {
        model.addQuestion(.int)
        let id = model.draft.questions[1].id
        let label = model.labelBinding(id)
        _ = model.draft.removeQuestion(id)
        #expect(label.wrappedValue == "")
        label.wrappedValue = "Ghost"
        #expect(model.draft.questions.count == 1)
    }
}
