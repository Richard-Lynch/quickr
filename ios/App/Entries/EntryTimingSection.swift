import QuickrCore
import QuickrUI
import SwiftUI

/// A timed entry's times, read-only (timers.md §11.2 "Entry details"): the total, then each
/// segment with its active time, the skipped steps and the pauses. Nothing for an untimed entry.
///
/// Accessibility identifiers: `entry.timing`, `entry.timing.total`, and 0-based in order
/// `entry.timing.segment.<i>`, `entry.timing.skipped.<i>` and `entry.timing.pause.<i>`.
/// `onEdit`, when given, adds an "Edit times" button (`entry.timing.edit`).
struct EntryTimingSection: View {
    let timing: Timing?
    /// The steps' labels by key, for the skipped ones (a step skipped has no segment to name it);
    /// a key not here reads as itself.
    var stepLabels: [String: String] = [:]
    var onEdit: (() -> Void)?

    var body: some View {
        if let timing {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Timing").font(.qr(.label)).foregroundStyle(.qr.inkSoft).accessibilityAddTraits(.isHeader)
                    Spacer()
                    RunDuration(ms: timing.activeMs, font: .qr(.callout))
                        .accessibilityLabel("Total \(RunPresentation.spoken(timing.activeMs))")
                        .accessibilityIdentifier("entry.timing.total")
                }
                VStack(spacing: 0) {
                    ForEach(Array(timing.segments.enumerated()), id: \.offset) { index, segment in
                        if index > 0 { Divider() }
                        HStack {
                            Text(segment.label).font(.qr(.body)).foregroundStyle(.qr.ink)
                            Spacer()
                            RunDuration(ms: segment.activeMs).foregroundStyle(.qr.muted)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: QuickrMetrics.tapTarget)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(segment.label), \(RunPresentation.spoken(segment.activeMs))")
                        .accessibilityIdentifier("entry.timing.segment.\(index)")
                    }
                }
                .qrCard()
                ForEach(Array(timing.skipped.enumerated()), id: \.offset) { index, step in
                    Text("Skipped: \(stepLabels[step] ?? step)")
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.muted)
                        .accessibilityIdentifier("entry.timing.skipped.\(index)")
                }
                ForEach(Array(timing.pauses.enumerated()), id: \.offset) { index, pause in
                    let ms = pause.end - pause.start
                    Text("Paused · \(DurationFormat.format(ms))")
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.muted)
                        .accessibilityLabel("Paused, \(RunPresentation.spoken(ms))")
                        .accessibilityIdentifier("entry.timing.pause.\(index)")
                }
                if let onEdit {
                    Button("Edit times", action: onEdit)
                        .buttonStyle(.qr(.secondary, size: .small))
                        .accessibilityIdentifier("entry.timing.edit")
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entry.timing")
        }
    }
}
