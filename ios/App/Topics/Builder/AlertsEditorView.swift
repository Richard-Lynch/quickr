import QuickrCore
import QuickrUI
import SwiftUI

/// The alerts of one step or lap type (`AlertsEditor`, timers2.md §1.6): each a label and an
/// expression over the draft's variables (`t/2`, `t+30s`, `1.5m`), evaluated as it is typed. The
/// result shows as "at 0:30"; an error shows the server's own message with the offending
/// character marked, so the field reads the same before and after submitting.
///
/// Behind a disclosure that shows the alert count while closed and opens itself when an alert
/// is added or one has an error. Identifiers, under the owner's `tag` (`newTopic.lap0`):
/// `.alerts` (the disclosure), `.alert<n>.label`, `.alert<n>.at`, `.alert<n>.key`,
/// `.alert<n>.result`, `.alert<n>.delete`, `.addAlert`.
struct AlertsEditor<Model: BuilderEditing>: View {
    @Bindable var model: Model
    let item: TimerItemID
    let owner: AlertOwner
    let tag: String
    /// "Run (lap type 1)": the accessibility labels' owner.
    let ownerName: String
    @FocusState private var focused: DraftAlert.ID?
    @QuickrReduceMotion private var reduceMotion

    var body: some View {
        let alerts = model.draft.alerts(of: item)
        let open = model.isOpen(item)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withQRAnimation(reduceMotion: reduceMotion) { model.toggle(item) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.qr(.caption))
                        .accessibilityHidden(true)
                    Text("Alerts").font(.qr(.subheadline))
                    if !alerts.isEmpty {
                        QuickrBadge("\(alerts.count)", tone: .neutral)
                    }
                    if model.draftErrors.hasError(inAlertsOf: owner) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.qr.danger)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.qr.muted)
                .frame(minHeight: QuickrMetrics.tapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Alerts for \(ownerName): \(alerts.count)")
            .accessibilityValue(open ? "Shown" : "Hidden")
            .accessibilityIdentifier("\(tag).alerts")
            if open {
                if alerts.isEmpty {
                    Text("No alerts. An alert cues you once this has run for a time, such as t/2 or t+30s.")
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.muted)
                }
                ForEach(Array(alerts.enumerated()), id: \.element.id) { j, alert in
                    row(j, alert)
                }
                TopicFieldError(model.draftErrors[.alerts(owner)])
                Button {
                    withQRAnimation(reduceMotion: reduceMotion) { focused = model.addAlert(to: item) }
                } label: {
                    Label("Add alert", systemImage: "plus").font(.qr(.subheadline))
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAddAlert(to: item))
                .accessibilityLabel("Add alert to \(ownerName)")
                .accessibilityIdentifier("\(tag).addAlert")
            }
        }
    }

    private func row(_ j: Int, _ alert: DraftAlert) -> some View {
        let tag = "\(self.tag).alert\(j)"
        let labelError = model.draftErrors[.alert(owner, j, .label)] ?? model.draftErrors[.alert(owner, j, .key)]
        return VStack(alignment: .leading, spacing: 4) {
            FieldRow(alignment: .center) {
                TextField("Alert name", text: model.alertLabelBinding(item, alert.id))
                    .focused($focused, equals: alert.id)
                    .accessibilityLabel("Alert \(j + 1) name")
                    .accessibilityIdentifier("\(tag).label")
                Button(role: .destructive) {
                    withQRAnimation(reduceMotion: reduceMotion) { model.removeAlert(item, alert.id) }
                } label: {
                    Image(systemName: "trash").foregroundStyle(.qr.muted)
                        .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove alert \(j + 1)")
                .accessibilityIdentifier("\(tag).delete")
            }
            TopicFieldError(labelError)
            FieldRow(alignment: .center) {
                TextField("t/2", text: model.alertAtBinding(item, alert.id))
                    .font(.qr(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityLabel("Alert \(j + 1) time")
                    .accessibilityIdentifier("\(tag).at")
                Text(alert.key.isEmpty ? "—" : alert.key)
                    .font(.qr(.monoCaption))
                    .foregroundStyle(.qr.muted)
                    .accessibilityLabel("Key \(alert.key.isEmpty ? "none yet" : alert.key)")
                    .accessibilityIdentifier("\(tag).key")
            }
            AlertResult(
                at: alert.at, preview: model.alertPreview(alert.at),
                formError: model.draftErrors[.alert(owner, j, .at)],
                tag: tag)
        }
        .padding(.vertical, 2)
        .padding(.leading, 12)
    }
}

/// An alert's live result ("at 0:30") or error: the message (the server's, after a submit) and the
/// expression with the character it points at marked (`AlertTime`).
struct AlertResult: View {
    let at: String
    let preview: AlertPreview
    let formError: String?
    let tag: String

    var body: some View {
        switch (formError, preview) {
        case (nil, .value(_, let text)):
            Text("at \(text)")
                .font(.qr(.footnote))
                .foregroundStyle(.qr.ok)
                .accessibilityIdentifier("\(tag).result")
        case (_, let preview):
            VStack(alignment: .leading, spacing: 2) {
                if case .error(_, let pos) = preview, !BuilderText.strip(at).isEmpty {
                    marked(pos)
                        .font(.qr(.monoCaption))
                        .accessibilityHidden(true)
                }
                let message: String =
                    if let formError { formError } else if case .error(let m, _) = preview { m } else { "" }
                Text(message)
                    .font(.qr(.footnote))
                    .foregroundStyle(formError == nil ? Color.qr.warn : Color.qr.danger)
                    .accessibilityLabel(formError == nil ? message : "Error: \(message)")
                    .accessibilityIdentifier("\(tag).result")
            }
        }
    }

    /// The expression with the code point at `pos` marked (a space past its end).
    private func marked(_ pos: Int) -> Text {
        let scalars = Array(at.unicodeScalars)
        func text(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        let start = Swift.min(Swift.max(0, pos), scalars.count)
        let end = Swift.min(start + 1, scalars.count)
        var mark = AttributedString(end > start ? text(start..<end) : " ")
        mark.foregroundColor = Color.qr.danger
        mark.backgroundColor = Color.qr.danger.opacity(0.15)
        mark.underlineStyle = .single
        var out = AttributedString(text(0..<start))
        out.foregroundColor = Color.qr.muted
        var rest = AttributedString(text(end..<scalars.count))
        rest.foregroundColor = Color.qr.muted
        out += mark
        out += rest
        return Text(out)
    }
}
