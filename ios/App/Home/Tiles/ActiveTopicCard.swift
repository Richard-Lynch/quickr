import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A timed topic with an open run, in home's "Active now" (active-surfaces.md §3.2): one tinted
/// card with the title and Pause/Resume, the segment clock with the run's total, the headline,
/// and the primary (Next or Lap) beside Stop. Tapping anywhere else opens the run screen.
///
/// Accessibility identifiers: `tile.<slug>` on the card; inside it `tile.<slug>.segment`,
/// `tile.<slug>.total`, `run.status` (the headline), `tile.<slug>.alert`, `tile.<slug>.run` (the
/// primary), `tile.<slug>.stop` and `tile.<slug>.pause` / `tile.<slug>.resume`.
struct ActiveTopicCard: View {
    let topic: ViewTopic
    let run: LocalRun
    /// Taps outside the controls: the run screen.
    let onOpen: () -> Void
    /// The card's colours. The one theme seam: M3 passes the topic's `TopicTheme`.
    var tint: ActiveCardTint = .accent

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let now = environment.runTicker.serverNow
        let paused = run.status == .paused
        let controls = ActiveCardControls(run)
        let stacked = typeSize.isAccessibilitySize
        let slug = topic.topic.slug
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                summary(now: now, paused: paused, slug: slug)
                if !stacked { pauseButton(controls, slug: slug) }
            }
            if stacked { pauseButton(controls, slug: slug) }
            if let alert = Self.alertLine(run) {
                Text(alert)
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.inkSoft)
                    .accessibilityIdentifier("tile.\(slug).alert")
            }
            controlsRow(controls, slug: slug, stacked: stacked)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Button(action: onOpen) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
        }
        .background(tint.tintSoft)
        .overlay(alignment: .leading) { tint.tint.frame(width: 4).accessibilityHidden(true) }
        .fixedSize(horizontal: false, vertical: true)
        .qrCard(border: tint.tint.opacity(0.45))
        .runTicking(!paused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(topic.topic.name)
        .accessibilityIdentifier("tile.\(slug)")
    }

    // MARK: - Rows

    /// The title, the clocks and the headline: for VoiceOver one element that opens the run, read
    /// first (§7).
    private func summary(now: Int, paused: Bool, slug: String) -> some View {
        let segment = RunPresentation.segmentMs(run.state, now: now)
        let total = RunPresentation.activeMs(run.state, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            Text(topic.topic.name)
                .font(.qr(.title))
                .tracking(-0.4)
                .foregroundStyle(.qr.ink)
                .fixedSize(horizontal: false, vertical: true)
            // The segment is the big clock: the lap is what the user is timing (D-7).
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RunDuration(
                    ms: run.state.open == nil ? total : segment,
                    font: .qr(.sansSemiBold, size: 40, relativeTo: .largeTitle), ticking: !paused
                )
                .foregroundStyle(paused ? Color.qr.muted : .qr.ink)
                .accessibilityIdentifier("tile.\(slug).segment")
                Text("total \(DurationFormat.format(total))")
                    .font(.qr(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.qr.inkSoft)
                    .lineLimit(1)
                    .accessibilityLabel("total \(RunPresentation.spoken(total))")
                    .accessibilityIdentifier("tile.\(slug).total")
            }
            QuickrBadge(Self.headline(run), icon: paused ? .pause : .timer, tone: paused ? .warn : .accent)
                .accessibilityIdentifier("run.status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text passes taps through to the open button behind it.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(paused ? [.isButton] : [.isButton, .updatesFrequently])
        .accessibilityHint("Opens the run")
        .accessibilityAction(.default, onOpen)
        .accessibilitySortPriority(3)
    }

    /// The small Pause/Resume text button: in the title row, under the headline at accessibility
    /// sizes (§3.2). A 44 pt target (the small size's hit area).
    private func pauseButton(_ controls: ActiveCardControls, slug: String) -> some View {
        Button {
            tap(controls.paused ? .resume : .pause)
        } label: {
            Label(controls.paused ? "Resume" : "Pause", systemImage: controls.paused ? "play" : "pause")
        }
        .buttonStyle(.qr(.ghost, size: .small))
        .disabled(busy)
        .accessibilityLabel(controls.paused ? "Resume" : "Pause")
        .accessibilityIdentifier("tile.\(slug).\(controls.paused ? "resume" : "pause")")
    }

    /// The primary filling the row, Stop beside it; stacked (both full width) at accessibility
    /// sizes.
    private func controlsRow(_ controls: ActiveCardControls, slug: String, stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button {
                switch controls.primary {
                case .next: tap(.next)
                case .lap: tap(.lap)
                }
            } label: {
                Label(controls.primary.title, systemImage: controls.primary.systemImage)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.qr(.primary, size: .large))
            .accessibilityLabel(controls.primary.title)
            .accessibilityIdentifier("tile.\(slug).run")
            .accessibilitySortPriority(2)
            Button(action: stop) {
                Label("Stop", systemImage: "stop")
                    .frame(maxWidth: stacked ? .infinity : nil)
                    .frame(minWidth: stacked ? nil : QuickrMetrics.logBlockWidth)
            }
            .buttonStyle(.qr(.secondary, size: .large))
            .fixedSize(horizontal: !stacked, vertical: false)
            .accessibilityLabel("Stop \(topic.topic.name)")
            .accessibilityIdentifier("tile.\(slug).stop")
            .accessibilitySortPriority(1)
        }
        .disabled(busy)
    }

    // MARK: - Taps

    private var busy: Bool { environment.runActions.isBusy(topic.topic.id) }

    private func tap(_ type: RunTapType) {
        // Captured now: a second tap before the card catches up targets what it showed.
        let (run, expect, actions) = (run, RunTapExpect(run), environment.runActions)
        Task { await actions.tap(type, run: run, expect: expect) }
    }

    private func stop() {
        let (run, expect, environment) = (run, RunTapExpect(run), environment)
        let (name, link) = (topic.topic.name, TopicLinkRef(id: topic.topic.id))
        Task {
            if let outcome = await environment.runActions.stop(run: run, topicName: name, expect: expect) {
                showStopOutcome(outcome, ref: link, in: environment)
            }
        }
    }

    // MARK: - Phase-2 seams (M1's presentation model)

    /// "Running · Lap 2" / "Paused · Shower". Until M1's `RunPresentation.headline` lands
    /// (active-surfaces.md §8.2): the open segment's label. Then: `headline(...).text`.
    static func headline(_ run: LocalRun) -> String {
        let status = run.status == .paused ? "Paused" : "Running"
        guard let open = run.state.open else { return status }
        return "\(status) · \(open.label)"
    }

    /// The next alert ("Half way · in 0:12"). Nil until M1's `RunPresentation.alertLine` lands
    /// (§8.2): the row collapses.
    static func alertLine(_ run: LocalRun) -> String? { nil }
}

/// The card's colours (§3.2): `tint` for the leading bar and the border, `tintSoft` behind the
/// card. The accent until M3's `TopicTheme` (appearance.md §4.1) lands; then the card takes the
/// topic's theme here and nowhere else.
struct ActiveCardTint {
    var tint: Color
    var tintSoft: Color

    static let accent = ActiveCardTint(tint: .qr.accent, tintSoft: .qr.accentSoft)
}

/// The card's buttons, from today's run model. Phase 2 replaces this adapter with M2-MODEL-ADOPT's
/// `RunControlsLayout` over M1's `RunPresentation.actions` (the typed "Lap → Rest" title, busy,
/// and the "Resuming…" projection's empty controls, §1.2 rows 11 and 14).
struct ActiveCardControls: Equatable {
    enum Primary: Equatable {
        case next(title: String)
        case lap

        var title: String {
            switch self {
            case .next(let title): title
            case .lap: "Lap"
            }
        }

        var systemImage: String {
            switch self {
            case .next: "chevron.right"
            case .lap: "flag"
            }
        }
    }

    var primary: Primary
    var paused: Bool

    /// Today's `RunPresentation.primary` is Next while a step remains, else Stop. Stop is never
    /// the primary (§1.2, D-2): it sits beside the primary, so its place goes to Lap.
    init(_ run: LocalRun) {
        switch RunPresentation.primary(run.state, steps: run.steps) {
        case .next(let label): primary = .next(title: label)
        case .stop: primary = .lap
        }
        paused = run.status == .paused
    }
}
