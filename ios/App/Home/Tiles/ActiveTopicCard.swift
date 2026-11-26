import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// A timed topic with an open run, in home's "Active now" (active-surfaces.md §3.2): one card in
/// the topic's tint with the title and Pause/Resume, the segment clock with the run's total, the
/// headline, the alert line, and the primary (Next or Lap) beside Stop. Tapping anywhere else
/// opens the run screen. The buttons are `RunControlsLayout.tile` over
/// `RunPresentation.actions`: placed by role, titled by kind (§1.3).
///
/// Accessibility identifiers: `tile.<slug>` on the card; inside it `tile.<slug>.segment`,
/// `tile.<slug>.total`, `run.status` (the headline), `tile.<slug>.alert`, `tile.<slug>.run` (the
/// primary), `tile.<slug>.stop` and `tile.<slug>.pause` / `tile.<slug>.resume`.
struct ActiveTopicCard: View {
    let topic: ViewTopic
    let run: LocalRun
    /// Taps outside the controls: the run screen.
    let onOpen: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The topic's colours (appearance.md §4.1), set by `.topicTheme(for:)`; the accent by default.
    @Environment(\.topicTheme) private var theme

    var body: some View {
        let now = environment.runTicker.serverNow
        let paused = run.status == .paused
        let timer = run.steps.map(TopicTimer.init(steps:))
        let resuming = Self.isResuming(run)
        // A queued reopen shows no controls until the ack (§1.2 row 11, §3.3).
        let controls =
            resuming
            ? RunControlsLayout.Tile(primary: nil, stop: nil, pauseResume: nil)
            : RunControlsLayout.tile(
                actions: RunPresentation.actions(run.state, status: run.status, timer: timer, now: RunInstant.date(now))
            )
        let alert = RunPresentation.alertLine(run.state, timer: timer, now: RunInstant.date(now))
        let stacked = typeSize.isAccessibilitySize
        let slug = topic.topic.slug
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                summary(now: now, timer: timer, paused: paused, resuming: resuming, slug: slug)
                if !stacked, let action = controls.pauseResume { pauseButton(action, slug: slug) }
            }
            if stacked, let action = controls.pauseResume { pauseButton(action, slug: slug) }
            if let alert {
                Text(alert)
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.inkSoft)
                    .accessibilityIdentifier("tile.\(slug).alert")
            }
            if controls.primary != nil || controls.stop != nil {
                controlsRow(controls, slug: slug, stacked: stacked)
            }
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
        .background(theme.tintSoft)
        .overlay(alignment: .leading) { theme.tint.frame(width: 4).accessibilityHidden(true) }
        .fixedSize(horizontal: false, vertical: true)
        .qrCard(border: theme.tint.opacity(0.45))
        .runTicking(!paused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(topic.topic.name)
        .accessibilityIdentifier("tile.\(slug)")
    }

    // MARK: - Rows

    /// The title, the clocks and the headline: for VoiceOver one element that opens the run, read
    /// first (§7).
    private func summary(now: Int, timer: TopicTimer?, paused: Bool, resuming: Bool, slug: String) -> some View {
        let segment = RunPresentation.segmentMs(run.state, now: now)
        let total = RunPresentation.activeMs(run.state, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The emoji when the topic has one; no initial, so an unthemed topic looks as before.
                TopicGlyphView(theme: theme, size: 24, fallbackInitial: false)
                Text(topic.topic.name)
                    .font(.qr(.title))
                    .tracking(-0.4)
                    .foregroundStyle(.qr.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            QuickrBadge(
                Self.headline(run, timer: timer, resuming: resuming), icon: paused ? .pause : .timer,
                tone: paused ? .warn : .accent
            )
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
    private func pauseButton(_ action: RunAction, slug: String) -> some View {
        let label = CardLabel(action, topic: topic.topic.name)
        return Button {
            perform(action)
        } label: {
            Label(label.title, systemImage: label.systemImage)
        }
        .buttonStyle(.qr(.ghost, size: .small))
        .disabled(!action.enabled || busy)
        .accessibilityLabel(label.spoken)
        .accessibilityIdentifier("tile.\(slug).\(action.id)")
    }

    /// The primary filling the row, Stop beside it; stacked (both full width) at accessibility
    /// sizes.
    private func controlsRow(_ controls: RunControlsLayout.Tile, slug: String, stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if let primary = controls.primary {
                let label = CardLabel(primary, topic: topic.topic.name)
                Button {
                    perform(primary)
                } label: {
                    Label(label.title, systemImage: label.systemImage)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.qr(.primary, size: .large))
                .disabled(!primary.enabled || busy)
                .accessibilityLabel(label.spoken)
                .accessibilityIdentifier("tile.\(slug).run")
                .accessibilitySortPriority(2)
            }
            if let stop = controls.stop {
                let label = CardLabel(stop, topic: topic.topic.name)
                Button {
                    perform(stop)
                } label: {
                    Label(label.title, systemImage: label.systemImage)
                        .frame(maxWidth: stacked ? .infinity : nil)
                        .frame(minWidth: stacked ? nil : QuickrMetrics.logBlockWidth)
                }
                .buttonStyle(.qr(.secondary, size: .large))
                .fixedSize(horizontal: !stacked, vertical: false)
                .disabled(!stop.enabled || busy)
                .accessibilityLabel(label.spoken)
                .accessibilityIdentifier("tile.\(slug).stop")
                .accessibilitySortPriority(1)
            }
        }
    }

    // MARK: - Taps

    /// The run's cooldown (`RunActions`), until `actions` reports it itself (§1.2 row 14).
    private var busy: Bool { environment.runActions.isBusy(topic.topic.id) }

    /// One of the card's controls. The card only ever holds an open run's primary (Next or Lap),
    /// Stop and Pause/Resume; anything else has no tap here.
    private func perform(_ action: RunAction) {
        // Captured now: a second tap before the card catches up targets what it showed.
        let (run, expect, environment) = (run, RunTapExpect(run), environment)
        let type: RunTapType
        switch action.kind {
        case .next: type = .next
        case .lap: type = .lap
        case .pause: type = .pause
        case .resume: type = .resume
        case .stop:
            let (name, link) = (topic.topic.name, TopicLinkRef(id: topic.topic.id))
            Task {
                if let outcome = await environment.runActions.stop(run: run, topicName: name, expect: expect) {
                    showStopOutcome(outcome, ref: link, in: environment)
                }
            }
            return
        case .start, .skip, .addDetails, .reopen, .revert, .discard:
            return
        }
        Task { await environment.runActions.tap(type, run: run, expect: expect) }
    }

    // MARK: - Text

    /// "Running · Rest 2 · lap 4" / "Paused · Shower" (`RunPresentation.headline`); "Running" alone
    /// when nothing is open; "Resuming…" while a reopen is queued.
    static func headline(_ run: LocalRun, timer: TopicTimer?, resuming: Bool) -> String {
        if resuming { return "Resuming…" }
        let status = run.status == .paused ? "Paused" : "Running"
        guard run.state.open != nil else { return status }
        return "\(status) · \(RunPresentation.headline(run.state, status: run.status, timer: timer).text)"
    }

    /// Seam, pending M1: the queued, unacked `reopen` of timers2.md §5.3 ("Resuming…", no
    /// controls until the ack, §3.3). M1 has no such projection on `LocalRun` yet, so a reopened
    /// run shows as plain "Running" (§8.2).
    static func isResuming(_ run: LocalRun) -> Bool { false }
}

/// A run action's title, SF Symbol and VoiceOver label on the home tiles (active-surfaces.md
/// §1.3).
struct CardLabel {
    var title: String
    var systemImage: String
    var spoken: String

    init(_ action: RunAction, topic: String) {
        switch action.kind {
        case .start: (title, systemImage, spoken) = ("Start", "play", "Start \(topic)")
        case .next(let label): (title, systemImage, spoken) = ("Next: \(label)", "chevron.right", "Next: \(label)")
        case .lap(nil): (title, systemImage, spoken) = ("Lap", "flag", "Lap")
        case .lap(let next?): (title, systemImage, spoken) = ("Lap → \(next)", "flag", "Lap, then \(next)")
        case .skip(let label): (title, systemImage, spoken) = ("Skip \(label)", "forward.end", "Skip \(label)")
        case .pause: (title, systemImage, spoken) = ("Pause", "pause", "Pause")
        case .resume: (title, systemImage, spoken) = ("Resume", "play", "Resume")
        case .stop: (title, systemImage, spoken) = ("Stop", "stop", "Stop \(topic)")
        case .addDetails: (title, systemImage, spoken) = ("Add details", "pencil", "Add details to \(topic)")
        case .reopen:
            (title, systemImage, spoken) = ("Resume run", "arrow.uturn.backward", "Resume the last run of \(topic)")
        case .revert:
            (title, systemImage, spoken) = ("Undo resume…", "arrow.uturn.forward", "Undo the resume and keep the stop")
        case .discard: (title, systemImage, spoken) = ("Discard run…", "trash", "Discard run")
        }
    }
}
