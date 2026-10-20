import QuickrCore
import QuickrUI
import SwiftUI

/// Captured at, notes and source: collapsed to a summary line, opened by an error in it (the
/// record and edit screens). `idPrefix` names its fields for UI tests (`<prefix>.capturedAt`, …).
struct EntryDetailsSection<Model: EntryDetailsEditing>: View {
    @Bindable var model: Model
    let idPrefix: String

    var body: some View {
        DisclosureGroup(isExpanded: $model.showsDetails) {
            VStack(alignment: .leading, spacing: 14) {
                field(error: model.metaErrors[.capturedAt]) {
                    DatePicker(
                        "Captured at", selection: $model.capturedAt, displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(.qr(.body))
                    .accessibilityIdentifier("\(idPrefix).capturedAt")
                }
                field(error: model.metaErrors[.notes]) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Notes").font(.qr(.label))
                            Text("optional").font(.qr(.sansMedium, size: 12, relativeTo: .caption))
                                .foregroundStyle(.qr.muted)
                        }
                        TextField("", text: $model.notes, axis: .vertical)
                            .lineLimit(2...6)
                            .font(.qr(.body))
                            .padding(12)
                            .background(
                                Color.qr.surface,
                                in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
                                    .strokeBorder(Color.qr.lineStrong, lineWidth: 1)
                            )
                            .accessibilityLabel("Notes")
                            .accessibilityIdentifier("\(idPrefix).notes")
                    }
                }
                field(error: model.metaErrors[.source]) {
                    if model.sourceIsEditable {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Source").font(.qr(.label))
                            TextField("e.g. phone", text: $model.source)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.qr(.body))
                                .padding(12)
                                .background(
                                    Color.qr.surface,
                                    in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
                                        .strokeBorder(Color.qr.lineStrong, lineWidth: 1)
                                )
                                .accessibilityLabel("Source")
                                .accessibilityIdentifier("\(idPrefix).source")
                        }
                    } else {
                        LabeledContent("Source", value: model.source)
                            .font(.qr(.body))
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                QIcon.clock.view(size: 16).foregroundStyle(.qr.muted)
                Text("Details").font(.qr(.callout))
                Text(summary).font(.qr(.subheadline)).foregroundStyle(.qr.muted).lineLimit(1)
                if !model.metaErrors.isEmpty {
                    QIcon.alert.view(size: 14).foregroundStyle(.qr.danger)
                }
            }
        }
        .tint(.qr.inkSoft)
        .padding(16)
        .qrCard()
        .accessibilityIdentifier("\(idPrefix).details")
    }

    private var summary: String {
        let when = model.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(when) · \(model.source)"
    }

    @ViewBuilder
    private func field(error: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let error {
                Text(error)
                    .font(.qr(.sansMedium, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(.qr.danger)
            }
        }
    }
}
