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

/// The tile's run line (§11.1): "Running · 4:12" (or "Paused · …") and the open segment with its
/// time; "Add details" for a finishing run.
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
                    if let open = run.state.open {
                        HStack(spacing: 4) {
                            Text(open.label).fontWeight(.semibold).foregroundStyle(.qr.inkSoft)
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
