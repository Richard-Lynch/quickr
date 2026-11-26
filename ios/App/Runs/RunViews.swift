import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

// The pieces the tile and the run screen share (timers.md §11.1, §11.2).

extension View {
    /// Holds the app's one run clock (`RunTicker`) while `active` and on screen: a running timer
    /// ticks, a paused or closed one doesn't.
    func runTicking(_ active: Bool) -> some View { modifier(RunTicking(active: active)) }
}

private struct RunTicking: ViewModifier {
    let active: Bool
    @Environment(AppEnvironment.self) private var environment
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                // A paused or closed clock shows a fresh "now" too, not the last tick's.
                environment.runTicker.refresh()
                hold(active)
            }
            .onDisappear { hold(false) }
            .onChange(of: active) { _, active in hold(active) }
    }

    private func hold(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        if wanted { environment.runTicker.retain() } else { environment.runTicker.release() }
    }
}

/// A duration, `m:ss` or `h:mm:ss`, in tabular digits; VoiceOver reads it in words.
struct RunDuration: View {
    let ms: Int
    var font: Font = .qr(.monoCaption)
    /// A running clock: VoiceOver is told it changes often.
    var ticking = false

    var body: some View {
        Text(DurationFormat.format(ms))
            .font(font)
            .monospacedDigit()
            // One line: a big clock shrinks at large text sizes rather than wrap its digits.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(RunPresentation.spoken(ms))
            .accessibilityAddTraits(ticking ? .updatesFrequently : [])
    }
}

/// The tile's run line (§11.1): "Running · 4:12" (or "Paused · …") and the headline with the
/// segment's time ("Rest 2 · lap 4 0:41"); "Add details" for a finishing run.
struct RunStatusLine: View {
    let run: LocalRun
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let now = environment.runTicker.serverNow
        let paused = run.status == .paused
        Group {
            if run.status == .finishing {
                QuickrBadge("Add details", icon: .edit, tone: .warn)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    QuickrBadge(
                        "\(paused ? "Paused" : "Running") · \(DurationFormat.format(RunPresentation.activeMs(run.state, now: now)))",
                        icon: paused ? .pause : .timer, tone: paused ? .warn : .accent
                    )
                    .monospacedDigit()
                    .accessibilityAddTraits(paused ? [] : .updatesFrequently)
                    .accessibilityLabel(
                        "\(paused ? "Paused" : "Running"), \(RunPresentation.spoken(RunPresentation.activeMs(run.state, now: now)))"
                    )
                    if let headline = RunHeadline.text(run) {
                        HStack(spacing: 4) {
                            Text(headline).fontWeight(.semibold).foregroundStyle(.qr.inkSoft)
                            RunDuration(
                                ms: RunPresentation.segmentMs(run.state, now: now), font: .qr(.footnote),
                                ticking: !paused)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .runTicking(run.status == .running)
        .accessibilityIdentifier("run.status")
    }
}

/// The open segment's headline (active-surfaces.md §2.1): M1's `RunPresentation.headline`, its
/// label with the counter ("Rest 2 · lap 4", "Shower · 2 of 5"); nil when nothing is open (the
/// badge already says Running or Paused).
enum RunHeadline {
    static func text(_ run: LocalRun) -> String? {
        guard run.state.open != nil else { return nil }
        return RunPresentation.headline(run.state, status: run.status, timer: run.timer).text
    }
}

extension LocalRun {
    /// The pinned version's timer, for M1's presentation model; nil when its steps aren't known
    /// here (the v1 fallback: a plain Next, no Skip).
    var timer: TopicTimer? { steps.map { TopicTimer(steps: $0) } }
}

/// The next alert and its countdown ("Half way · in 0:12"), under the headline; nothing when
/// there is none.
///
/// The text is M1's `RunPresentation.alertLine`, which also keeps a fired alert's label for 10 s
/// (timers2.md §9) and is nil while paused.
struct RunAlertLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "bell")
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.inkSoft)
                .monospacedDigit()
                .accessibilityIdentifier("run.alert")
        }
    }
}

/// What Stop leads to, on any surface: the answers form, or "Saved X: 7:42".
@MainActor
func showStopOutcome(_ outcome: RunActions.StopOutcome, ref: TopicLinkRef, in environment: AppEnvironment) {
    switch outcome {
    case .details(let runId):
        guard let id = UUID(uuidString: runId) else { return }
        environment.router.open(.runDetails(ref, runId: id))
    case .saved(let name, let total):
        environment.toasts.show(Toast("Saved \(name): \(DurationFormat.format(total))"))
    }
}
