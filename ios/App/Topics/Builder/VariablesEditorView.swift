import QuickrCore
import QuickrUI
import SwiftUI

/// The variables alerts refer to (`VariablesEditor`, timers2.md §1.6): a name, lowercased as it
/// is typed, and a duration entered as `m:ss` or `h:mm:ss`. Identifiers: `<id>.variable<n>.name`,
/// `.duration`, `.delete`, `<id>.addVariable`, `<id>.noVariables`.
struct VariablesSection<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let id: String
    @FocusState private var focused: DraftVariable.ID?
    @QuickrReduceMotion private var reduceMotion

    var body: some View {
        Section {
            if model.draft.variables.isEmpty {
                Text("No variables. Add one to write alerts like t/2 or t+30s.")
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                    .accessibilityIdentifier("\(id).noVariables")
            }
            ForEach(Array(model.draft.variables.enumerated()), id: \.element.id) { index, variable in
                row(index, variable)
            }
            Button {
                withQRAnimation(reduceMotion: reduceMotion) { focused = model.addVariable() }
            } label: {
                Label("Add variable", systemImage: "plus")
            }
            .disabled(!model.draft.canAddVariable(limits: model.limits))
            .accessibilityIdentifier("\(id).addVariable")
            TopicFieldError(model.draftErrors[.variables])
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Variables")
                Text("\(model.draft.variables.count)").font(.qr(.monoCaption))
            }
        }
    }

    /// "t (variable 1)", or "variable 1" while it has no name.
    private func name(_ index: Int, _ variable: DraftVariable) -> String {
        variable.name.isEmpty ? "variable \(index + 1)" : "\(variable.name) (variable \(index + 1))"
    }

    private func row(_ index: Int, _ variable: DraftVariable) -> some View {
        let tag = "\(id).variable\(index)"
        return VStack(alignment: .leading, spacing: 4) {
            FieldRow(alignment: .center) {
                TextField("Name", text: model.variableNameBinding(variable.id))
                    .font(.qr(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: variable.id)
                    .accessibilityLabel("Variable \(index + 1) name")
                    .accessibilityIdentifier("\(tag).name")
                TextField("m:ss", text: model.variableDurationBinding(variable.id))
                    .font(.qr(.mono))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Variable \(index + 1) duration, minutes and seconds")
                    .accessibilityIdentifier("\(tag).duration")
                Button(role: .destructive) {
                    withQRAnimation(reduceMotion: reduceMotion) { model.draft.removeVariable(variable.id) }
                } label: {
                    Image(systemName: "trash").foregroundStyle(.qr.muted)
                        .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(name(index, variable))")
                .accessibilityIdentifier("\(tag).delete")
            }
            TopicFieldError(model.draftErrors[.variable(index, .name)])
            TopicFieldError(model.draftErrors[.variable(index, .duration)])
        }
        .padding(.vertical, 2)
    }
}
