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

/// The run screen's alert line (active-surfaces.md §2.1, `RunHeaderText.alert`): for 10 s after an
/// alert fires in the foreground, its label with a bell (`fired`, I1-ALERTS'
/// `runAlerts.label(runId:)`); otherwise the next alert and its countdown ("Half way · in 0:12",
/// M1's `RunPresentation.alertLine`, nil while paused). Nothing when there is neither.
struct RunAlertLine: View {
    let fired: String?
    let next: String?

    var body: some View {
        if let line = RunHeaderText.alert(fired: fired, next: next) {
            Label(line.text, systemImage: line.fired ? "bell.fill" : "bell")
                .font(.qr(line.fired ? .callout : .subheadline))
                .fontWeight(line.fired ? .semibold : nil)
                .foregroundStyle(line.fired ? Color.qr.ink : .qr.inkSoft)
                .monospacedDigit()
                .accessibilityLabel(line.fired ? "Alert: \(line.text)" : line.text)
                .accessibilityIdentifier("run.alert")
        }
    }
}

/// What Stop leads to, on any surface: the answers form, or "Saved X: 7:42" with **Resume**
/// (active-surfaces.md §3.2, OQ-1): a reopen of `run`, the one just stopped. A run stopped this
/// moment is resumable (its stop is the latest, unedited, seconds old), so the toast offers it
/// at once; the tap re-checks the store (`LocalStore.resumable`), since the toast can outlive a
/// later start, an edit of the entry or another device's stop, and then does nothing.
@MainActor
func showStopOutcome(
    _ outcome: RunActions.StopOutcome, run: LocalRun, ref: TopicLinkRef, in environment: AppEnvironment
) {
    switch outcome {
    case .details(let runId):
        guard let id = UUID(uuidString: runId) else { return }
        environment.router.open(.runDetails(ref, runId: id))
    case .saved(let name, let total):
        let (runId, topicId, actions, ticker) = (run.id, run.topicId, environment.runActions, environment.runTicker)
        let store = environment.session?.store
        let resume = Toast.Action("Resume") {
            Task {
                guard let latest = try? await store?.resumable(topicId: topicId), latest.runId == runId,
                    latest.isOffered(at: RunInstant.milliseconds(Date()) + ticker.offsetMs)
                else { return }
                await actions.reopen(runId: runId, topicId: topicId)
            }
        }
        environment.toasts.show(Toast("Saved \(name): \(DurationFormat.format(total))", action: resume))
    }
}
