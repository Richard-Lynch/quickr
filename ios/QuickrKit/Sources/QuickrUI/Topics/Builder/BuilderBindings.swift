import QuickrCore
import SwiftUI

/// The builder's field bindings. Each one reads the model's draft *now*, by the question's (and
/// option's) id, never a value captured when the view last rendered: under load SwiftUI can read
/// a field's binding between renders, and a captured value would hand it the text from before the
/// latest keystrokes, which it then writes back over them ("Glasses of water" → "Glasses of w").
/// Writes go through `TopicDraft`'s rules (a label's derived key, published keys fixed…).
///
/// Unlike QuickrUI's views, this file isn't `#if os(iOS)`: `Binding` exists on macOS too, so the
/// host tests (`BuilderBindingsTests`) run it.
extension BuilderEditing {
    /// A plain field of a question (help text, required, constraints).
    public func binding<Value>(
        _ id: DraftQuestion.ID, _ path: WritableKeyPath<DraftQuestion, Value>, default value: Value
    ) -> Binding<Value> {
        Binding(
            get: { self.draft[id]?[keyPath: path] ?? value },
            set: { newValue in
                guard let i = self.draft.index(of: id) else { return }
                self.draft.questions[i][keyPath: path] = newValue
            })
    }

    public func labelBinding(_ id: DraftQuestion.ID) -> Binding<String> {
        Binding(get: { self.draft[id]?.label ?? "" }, set: { self.draft.setLabel(id, $0) })
    }

    public func keyBinding(_ id: DraftQuestion.ID) -> Binding<String> {
        Binding(get: { self.draft[id]?.key ?? "" }, set: { _ = self.draft.setKey(id, $0) })
    }

    public func typeBinding(_ id: DraftQuestion.ID, default type: QuestionType) -> Binding<QuestionType> {
        Binding(get: { self.draft[id]?.type ?? type }, set: { _ = self.draft.setType(id, to: $0) })
    }

    public func multipleBinding(_ id: DraftQuestion.ID) -> Binding<Bool> {
        Binding(get: { self.draft[id]?.multiple ?? false }, set: { _ = self.draft.setMultiple(id, $0) })
    }

    public func optionLabelBinding(_ id: DraftQuestion.ID, option: DraftOption.ID) -> Binding<String> {
        Binding(
            get: { self.option(id, option)?.label ?? "" },
            set: { self.draft.setOptionLabel(id, option: option, $0) })
    }

    public func optionValueBinding(_ id: DraftQuestion.ID, option: DraftOption.ID) -> Binding<String> {
        Binding(
            get: { self.option(id, option)?.value ?? "" },
            set: { _ = self.draft.setOptionValue(id, option: option, $0) })
    }

    /// A step's label; a new step's key follows it, with the topic's step history.
    public func stepLabelBinding(_ id: DraftStep.ID) -> Binding<String> {
        Binding(
            get: { self.draft.stepIndex(of: id).map { self.draft.steps[$0].label } ?? "" },
            set: { self.setStepLabel(id, $0) })
    }

    /// A lap type's label; a new one's key follows it, with the topic's timer history.
    public func lapTypeLabelBinding(_ id: DraftLapType.ID) -> Binding<String> {
        Binding(
            get: { self.draft.lapTypeIndex(of: id).map { self.draft.laps[$0].label } ?? "" },
            set: { self.setLapTypeLabel(id, $0) })
    }

    /// A variable's name, lowercased as it is typed.
    public func variableNameBinding(_ id: DraftVariable.ID) -> Binding<String> {
        Binding(
            get: { self.draft.variableIndex(of: id).map { self.draft.variables[$0].name } ?? "" },
            set: { self.draft.setVariableName(id, $0) })
    }

    /// A variable's duration text (`m:ss` or `h:mm:ss`).
    public func variableDurationBinding(_ id: DraftVariable.ID) -> Binding<String> {
        Binding(
            get: { self.draft.variableIndex(of: id).map { self.draft.variables[$0].duration } ?? "" },
            set: { self.draft.setVariableDuration(id, $0) })
    }

    /// An alert's label; a new one's key follows it.
    public func alertLabelBinding(_ item: TimerItemID, _ id: DraftAlert.ID) -> Binding<String> {
        Binding(
            get: { self.draft.alerts(of: item).first { $0.id == id }?.label ?? "" },
            set: { self.setAlertLabel(item, id, $0) })
    }

    /// An alert's expression, as typed.
    public func alertAtBinding(_ item: TimerItemID, _ id: DraftAlert.ID) -> Binding<String> {
        Binding(
            get: { self.draft.alerts(of: item).first { $0.id == id }?.at ?? "" },
            set: { self.draft.setAlertAt(item, id, $0) })
    }

    /// The Timed switch. Off keeps the timer's lists (unsent), so switching it back on restores them.
    public var timedBinding: Binding<Bool> {
        Binding(get: { self.draft.timed }, set: { self.draft.timed = $0 })
    }

    /// The "Add an option…" text of a question.
    public func newOptionBinding(_ id: DraftQuestion.ID) -> Binding<String> {
        Binding(get: { self.newOptionLabels[id] ?? "" }, set: { self.newOptionLabels[id] = $0 })
    }

    private func option(_ id: DraftQuestion.ID, _ option: DraftOption.ID) -> DraftOption? {
        draft[id]?.options.first { $0.id == option }
    }
}
