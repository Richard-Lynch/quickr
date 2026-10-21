#if os(iOS)
import QuickrCore
import SwiftUI

/// One question as the control for its type (the PWA's `AnswerField`), with its label, the
/// "optional" tag, help text and inline error:
/// - int/double: ``NumberStepper`` (unit, range placeholder, a keyboard with minus when the
///   range allows negatives);
/// - str: a single-line field, or a growing multi-line one, with a code-point counter;
/// - single-select: ``ChipGrid`` up to `Question.chipLimit` options, otherwise a menu picker
///   ("Choose…" or "— none —");
/// - multi-select: ``ChipGrid`` with the "pick 1–3" hint, dimming at the maximum.
///
/// Stateless: the caller owns the input. ``FormView`` drives it from a ``FormModel``.
public struct AnswerField: View {
    let question: Question
    @Binding var input: AnswerInput
    let options: [EnumOption]
    let error: String?
    let characterCount: CharacterCount?
    let focus: FocusState<Bool>.Binding?
    let submitLabel: SubmitLabel
    let onSubmit: () -> Void
    let voiceOverRequest: FormVoiceOverRequest?

    @FocusState private var ownFocus: Bool

    /// - Parameters:
    ///   - options: for choices, usually `question.visibleOptions(keeping:)`.
    ///   - focus: lets a form drive keyboard focus (number and text questions).
    ///   - submitLabel, onSubmit: the Return key of a single-line text or number field.
    ///   - voiceOverRequest: each new one moves VoiceOver here, to the error or the question's
    ///     label as the request says (fixed when it was made, not by the live error).
    public init(
        question: Question, input: Binding<AnswerInput>, options: [EnumOption]? = nil, error: String? = nil,
        characterCount: CharacterCount? = nil, focus: FocusState<Bool>.Binding? = nil,
        submitLabel: SubmitLabel = .next, onSubmit: @escaping () -> Void = {},
        voiceOverRequest: FormVoiceOverRequest? = nil
    ) {
        self.question = question
        self._input = input
        self.options = options ?? question.visibleOptions()
        self.error = error
        self.characterCount = characterCount
        self.focus = focus
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.voiceOverRequest = voiceOverRequest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let help = question.helpText, !help.isEmpty {
                Text(help)
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                    .padding(.top, -4)
            }
            control
            if let error {
                Text(error)
                    .font(.qr(.sansMedium, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(.qr.danger)
                    .accessibilityIdentifier("form.error.\(question.key)")
                    .qrMovesVoiceOverFocus(on: voiceOverRequest.flatMap { $0.toError ? $0.serial : nil })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The label and "optional" flow as one text, so a long label wraps between words; the
    /// trailing hint or counter moves under it when both don't fit on one line.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleView.fixedSize()
                Spacer(minLength: 0)
                trailing
            }
            VStack(alignment: .leading, spacing: 2) {
                titleView.fixedSize(horizontal: false, vertical: true)
                trailing
            }
        }
    }

    /// The label as a heading (VoiceOver's headings rotor steps through a long form), where a
    /// fresh form's VoiceOver starts.
    private var titleView: some View {
        title
            .accessibilityAddTraits(.isHeader)
            .qrMovesVoiceOverFocus(on: voiceOverRequest.flatMap { $0.toError ? nil : $0.serial })
    }

    private var title: Text {
        let label = Text(question.label).font(.qr(.label)).foregroundStyle(.qr.ink)
        guard !question.required else { return label }
        let tag = Text("optional").font(.qr(.sansMedium, size: 12, relativeTo: .caption)).foregroundStyle(.qr.muted)
        return label + Text("  ") + tag
    }

    @ViewBuilder
    private var trailing: some View {
        if let bounds = SelectionBounds(question), case .selection(let picked) = input {
            Text(picked.isEmpty ? bounds.hint.lowercased() : "\(picked.count) selected · \(bounds.hint.lowercased())")
                .font(.qr(.monoCaption))
                .foregroundStyle(.qr.muted)
                .accessibilityHidden(true)
        } else if let characterCount {
            Text(characterCount.text)
                .font(.qr(.monoCaption))
                .foregroundStyle(characterCount.isOver ? .qr.danger : .qr.muted)
                .accessibilityLabel("\(characterCount.count) of \(characterCount.max) characters")
        }
    }

    @ViewBuilder
    private var control: some View {
        switch question.kind {
        case .int, .double:
            let rules = question.numericRules
            NumberStepper(
                text: textBinding,
                rule: NumberStepRule(
                    integer: rules?.isInteger ?? true, min: rules?.min, max: rules?.max, decimals: rules?.decimals),
                unit: rules?.unit.flatMap { $0.isEmpty ? nil : $0 }, label: question.label,
                isInvalid: error != nil, focus: focus ?? $ownFocus
            )
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .accessibilityIdentifier("form.field.\(question.key)")
            .accessibilityHint(errorHint)
        case .string(let rules):
            TextAnswerControl(
                label: question.label, text: textBinding, multiline: rules.multiline, isInvalid: error != nil,
                focus: focus ?? $ownFocus
            )
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .accessibilityIdentifier("form.field.\(question.key)")
            .accessibilityHint(errorHint)
        case .choice(let rules) where rules.multiple:
            let bounds = SelectionBounds(question: question, rules: rules)
            ChipGrid(
                question.label, options: chipOptions, selection: selectionBinding, min: bounds.min, max: bounds.max,
                isInvalid: error != nil)
        case .choice:
            if question.usesChoicePicker {
                ChoicePicker(
                    label: question.label, options: options, required: question.required, value: textBinding,
                    isInvalid: error != nil
                )
                .accessibilityIdentifier("form.field.\(question.key)")
                .accessibilityHint(errorHint)
            } else {
                ChipGrid(
                    question.label, options: chipOptions, selection: singleBinding, required: question.required,
                    isInvalid: error != nil)
            }
        }
    }

    /// A field's error as its hint, so VoiceOver says it with the field (chips say theirs on the
    /// group's error text, which follows them).
    private var errorHint: String { error.map { "Error: \($0)" } ?? "" }

    private var chipOptions: [ChipOption] { options.map { ChipOption($0.value, label: $0.label) } }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                switch input {
                case .text(let s): s
                case .selection(let values): values.first ?? ""
                }
            },
            set: { input = .text($0) })
    }

    private var singleBinding: Binding<String?> {
        Binding(
            get: { textBinding.wrappedValue.isEmpty ? nil : textBinding.wrappedValue },
            set: { input = .text($0 ?? "") })
    }

    private var selectionBinding: Binding<[String]> {
        Binding(
            get: {
                switch input {
                case .selection(let values): values
                case .text(let s): s.isEmpty ? [] : [s]
                }
            },
            set: { input = .selection($0) })
    }
}

/// A bordered text field; multi-line ones grow from three lines and Return adds a line.
private struct TextAnswerControl: View {
    let label: String
    @Binding var text: String
    let multiline: Bool
    let isInvalid: Bool
    let focus: FocusState<Bool>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
        Group {
            if multiline {
                TextField(text: $text, prompt: Text(""), axis: .vertical) { Text(label) }
                    .lineLimit(3...8)
            } else {
                TextField(text: $text, prompt: Text("")) { Text(label) }
            }
        }
        .focused(focus)
        .font(.qr(.body))
        .foregroundStyle(.qr.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: QuickrMetrics.chipHeight)
        .background(Color.qr.surface, in: shape)
        .overlay(shape.strokeBorder(border, lineWidth: 1))
        .background(shape.inset(by: -3).fill(focus.wrappedValue && !isInvalid ? Color.qr.accent.opacity(0.2) : .clear))
    }

    private var border: Color {
        if isInvalid { return .qr.danger }
        return focus.wrappedValue ? .qr.accent : .qr.lineStrong
    }
}

/// A single-select with too many options for chips: a full-width menu with a checkmarked list.
/// The blank choice reads "Choose…" when required and "— none —" when optional (the PWA's
/// `<select>`).
private struct ChoicePicker: View {
    let label: String
    let options: [EnumOption]
    let required: Bool
    @Binding var value: String
    let isInvalid: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
        Menu {
            Picker(label, selection: $value) {
                Text(placeholder).tag("")
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            HStack {
                Text(selected?.label ?? placeholder)
                    .font(.qr(.body))
                    .foregroundStyle(selected == nil ? .qr.muted : .qr.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Spacer(minLength: 8)
                QIcon.chevronDown.view(size: 14)
                    .foregroundStyle(.qr.muted)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: QuickrMetrics.chipHeight)
            .background(Color.qr.surface, in: shape)
            .overlay(shape.strokeBorder(isInvalid ? Color.qr.danger : .qr.lineStrong, lineWidth: 1))
            .contentShape(shape)
        }
        .accessibilityLabel(label)
        .accessibilityValue(selected?.label ?? "None selected")
    }

    private var placeholder: String { required ? "Choose…" : "— none —" }

    private var selected: EnumOption? { options.first { $0.value == value } }
}
#endif
