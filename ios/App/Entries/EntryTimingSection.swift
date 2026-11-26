import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A timed entry's times, read-only (timers.md §11.2 "Entry details"): the total, then each
/// segment with its active time and, in the same list, the pauses between the segments they fall
/// in (content-display.md §3.2, `EntryTimingModel.rows`), then the skipped steps. Nothing for an
/// untimed entry.
///
/// Accessibility identifiers: `entry.timing`, `entry.timing.total`, and 0-based in order
/// `entry.timing.segment.<i>`, `entry.timing.skipped.<i>` and `entry.timing.pause.<i>`.
/// `onEdit`, when given, adds an "Edit times" button (`entry.timing.edit`); `editUnavailable` says
/// why there's none. `showsStatus` adds the "edited" and "incomplete" badges (the edit screen).
///
/// A typed lap shows its type in a neutral badge. With `actions` (the entry detail), lap and pause
/// rows get a one-tap Remove beside them (`entry.timing.remove.<i>`,
/// `entry.timing.pause.remove.<j>`; `EntryTimingModel.remove`) behind a confirmation, and a
/// queued remove's re-projected timing shows "Waiting" (`entry.timing.pending`) until the ack.
struct EntryTimingSection: View {
    let timing: Timing?
    /// The steps' labels by key, for the skipped ones (a step skipped has no segment to name it);
    /// a key not here reads as itself.
    var stepLabels: [String: String] = [:]
    /// The run's version's lap types, for the typed laps' badges.
    var lapTypes: [TopicTimer.LapType] = []
    var onEdit: (() -> Void)?
    var showsStatus = false
    var editUnavailable: String?
    var actions: EntryActionsModel?
    @State private var confirming: EntryTimingModel.Remove?

    var body: some View {
        if let timing {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Timing").font(.qr(.label)).foregroundStyle(.qr.inkSoft).accessibilityAddTraits(.isHeader)
                    if showsStatus && timing.edited { QuickrBadge("edited", tone: .info) }
                    if showsStatus && !timing.complete { QuickrBadge("incomplete", tone: .warn) }
                    if actions?.isPending == true {
                        QuickrBadge("Waiting", icon: .clock, tone: .info)
                            .accessibilityLabel("Change waiting to sync")
                            .accessibilityIdentifier("entry.timing.pending")
                    }
                    Spacer()
                    RunDuration(ms: timing.activeMs, font: .qr(.callout))
                        .accessibilityLabel("Total \(RunPresentation.spoken(timing.activeMs))")
                        .accessibilityIdentifier("entry.timing.total")
                }
                VStack(spacing: 0) {
                    let rows = EntryTimingModel.rows(timing)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                        if position > 0 { Divider() }
                        switch row {
                        case .segment(let index, let segment):
                            let badge = EntryTimingModel.lapTypeBadge(segment, lapTypes: lapTypes)
                            HStack(spacing: 4) {
                                HStack {
                                    Text(segment.label).font(.qr(.body)).foregroundStyle(.qr.ink)
                                    if let badge { QuickrBadge(badge) }
                                    Spacer()
                                    RunDuration(ms: segment.activeMs).foregroundStyle(.qr.muted)
                                }
                                .frame(minHeight: QuickrMetrics.tapTarget)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(
                                    [
                                        segment.label, badge.map { "type \($0)" },
                                        RunPresentation.spoken(segment.activeMs),
                                    ]
                                    .compactMap { $0 }.joined(separator: ", ")
                                )
                                .accessibilityIdentifier("entry.timing.segment.\(index)")
                                removeButton(row)
                            }
                            .padding(.horizontal, 14)
                        case .pause(let index, let pause):
                            let ms = pause.end - pause.start
                            HStack(spacing: 4) {
                                HStack {
                                    Text("Paused · \(DurationFormat.format(ms))")
                                        .font(.qr(.footnote))
                                        .foregroundStyle(.qr.muted)
                                    Spacer()
                                }
                                .frame(minHeight: QuickrMetrics.tapTarget)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Paused, \(RunPresentation.spoken(ms))")
                                .accessibilityIdentifier("entry.timing.pause.\(index)")
                                removeButton(row)
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                }
                .qrCard()
                ForEach(Array(timing.skipped.enumerated()), id: \.offset) { index, step in
                    Text("Skipped: \(stepLabels[step] ?? step)")
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.muted)
                        .accessibilityIdentifier("entry.timing.skipped.\(index)")
                }
                if let onEdit {
                    Button("Edit times", action: onEdit)
                        .buttonStyle(.qr(.secondary, size: .small))
                        .accessibilityIdentifier("entry.timing.edit")
                } else if let editUnavailable {
                    Text(editUnavailable).font(.qr(.footnote)).foregroundStyle(.qr.muted)
                        .accessibilityIdentifier("entry.timing.editUnavailable")
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entry.timing")
            .alert(
                confirming?.title ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { remove in
                Button("Remove", role: .destructive) {
                    guard let actions else { return }
                    Task { await actions.remove(remove) }
                }
                .accessibilityIdentifier("entry.timing.remove.confirm")
                Button("Cancel", role: .cancel) {}
            } message: { remove in
                Text(remove.message)
            }
        }
    }

    /// The row's Remove, when it has one (the detail only): its own accessibility element, beside
    /// the row's.
    @ViewBuilder private func removeButton(_ row: EntryTimingModel.Row) -> some View {
        if let actions, let remove = actions.removeAction(row) {
            QuickrIconButton(.trash, label: "Remove", small: true) { confirming = remove }
                .disabled(!remove.enabled)
                .opacity(remove.enabled ? 1 : 0.4)
                .accessibilityHint(remove.enabled ? "" : "The lap after the last step can’t be removed.")
                .accessibilityIdentifier(remove.identifier)
        }
    }
}
