import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// `/t/:ref/run` (`quickr://t/{topic_id}/run`): a timed topic's run screen (timers.md §11.2).
/// Finds the topic and follows its runs in the local view, then shows `RunPanel` for its open
/// run, Add details for a finishing one, or Start.
struct RunScreen: View {
    let ref: TopicLinkRef
    @Environment(AppEnvironment.self) private var environment
    @State private var topic: Topic?
    @State private var runs: [LocalRun] = []
    @State private var missing = false

    var body: some View {
        Group {
            if let topic {
                RunPanel(topic: topic, run: Self.shown(runs))
            } else if missing {
                Text("Topic not found. It may have been deleted.")
                    .font(.qr(.body))
                    .foregroundStyle(.qr.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .qrPaperBackground()
                    .accessibilityIdentifier("run.missing")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .qrPaperBackground()
            }
        }
        .task(id: environment.session?.binding) { await followTopic() }
        .task(id: RunsKey(binding: environment.session?.binding, topicId: topic?.id)) { await followRuns(topic?.id) }
    }

    /// The run the screen is about: the topic's open run, else its latest finishing one.
    static func shown(_ runs: [LocalRun]) -> LocalRun? {
        runs.first(where: \.isOpen) ?? runs.last { $0.status == .finishing }
    }

    /// The topic, kept current, until the binding changes.
    private func followTopic() async {
        guard let session = environment.session, let store = session.store else { return }
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                let found = topics.first { ref.matches($0.topic) }?.topic
                topic = found
                missing = found == nil
            }
        } catch {
            // the store closed: the next binding observes again
        }
    }

    /// The topic's local runs, once the topic is known.
    private func followRuns(_ topicId: UUID?) async {
        guard let topicId, let session = environment.session, let store = session.store else { return }
        do {
            for try await all in store.observeLocalRuns(topicId: topicId, refresh: session.refresh.stream()) {
                runs = all
            }
        } catch {
            // as above
        }
    }

    private struct RunsKey: Hashable {
        var binding: AppSession.Binding?
        var topicId: UUID?
    }
}

/// The run screen's body for `topic` (active-surfaces.md §2.1): a header, the controls under it,
/// then the step and lap table, for its open run, a finishing run's Add details, or Start. Also
/// the record screen's, for a timed topic. The whole screen scrolls; the controls aren't pinned.
struct RunPanel: View {
    let topic: Topic
    let run: LocalRun?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var starts = 0
    @State private var advances = 0
    @State private var stops = 0

    private var link: TopicLinkRef { TopicLinkRef(id: topic.id) }

    var body: some View {
        let slots = RunControlItem.slots(controls)
        let busy = environment.runActions.isBusy(topic.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let run, run.isOpen {
                    OpenRunView(run: run) { RunControls(slots, busy: busy) }
                } else if let run, run.status == .finishing {
                    finishing(run, controls: RunControls(slots, busy: busy))
                } else {
                    idle(controls: RunControls(slots, busy: busy))
                }
            }
            .padding(16)
        }
        .qrPaperBackground()
        .navigationTitle(topic.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !slots.menu.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { RunOverflowMenu(items: slots.menu, busy: busy) }
            }
        }
        .alert("Discard this run?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep timing", role: .cancel) {}
        } message: {
            Text("Its times won’t be saved. This can’t be undone.")
        }
        .qrHaptic(.logged, trigger: starts)
        .qrHaptic(.selection, trigger: advances)
        .qrHaptic(.logged, trigger: stops)
    }

    // MARK: - States

    private func idle(controls: RunControls) -> some View {
        let steps = topic.timer?.steps ?? []
        return VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 6) {
                RunDuration(ms: 0, font: .qr(.sansSemiBold, size: 60, relativeTo: .largeTitle))
                    .foregroundStyle(.qr.muted)
                Text(
                    steps.isEmpty
                        ? "One tap starts the timer; Stop saves it."
                        : "\(steps.count) \(steps.count == 1 ? "step" : "steps"), timed in order."
                )
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
            }
            .frame(maxWidth: .infinity)
            if topic.status == .archived {
                Text("This topic is archived. Unarchive it to time it.")
                    .font(.qr(.subheadline))
                    .foregroundStyle(QuickrTone.warn.foreground)
                    .accessibilityIdentifier("run.archived")
            }
            controls
            if !steps.isEmpty {
                StepList(rows: RunPresentation.rows(steps: steps), liveMs: 0)
            }
        }
    }

    private func finishing(_ run: LocalRun, controls: RunControls) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            QuickrBadge("Stopped", icon: .stop, tone: .warn)
            RunDuration(
                ms: RunPresentation.activeMs(run.state, now: run.state.endedAt ?? run.state.startedAt),
                font: .qr(.sansSemiBold, size: 60, relativeTo: .largeTitle)
            )
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("run.total")
            Text("Add the details to save it.")
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
            controls.padding(.vertical, 8)
            StepList(rows: RunPresentation.rows(run.state, steps: run.steps), liveMs: 0)
        }
    }

    // MARK: - Controls

    /// The screen's controls in display order, each with its place (§2.2).
    ///
    /// Phase-1 seam (I2-CONTROLS): today's taps, given the roles of active-surfaces.md §1.2
    /// (Lap is the primary on a lap or once no named step remains; Stop and Pause/Resume are the
    /// secondaries; Skip and Discard sit in the menu). Phase 2 replaces this with M1's
    /// `RunPresentation.actions(_:status:timer:now:)` placed by `RunControlsLayout`.
    private var controls: [RunControlItem] {
        if let run, run.isOpen {
            let paused = run.status == .paused
            let primary = RunPresentation.primary(run.state, steps: run.steps)
            let lap = run.steps != nil && (run.state.open?.kind == .lap || !primary.isNext)
            var items = [
                lap
                    ? RunControlItem(
                        id: "run.primary", title: "Lap", icon: "flag", role: .primary,
                        enabled: run.state.open != nil, perform: { advance(.lap, run) })
                    : RunControlItem(
                        id: "run.primary", title: primary.title, icon: "chevron.right", role: .primary,
                        perform: { advance(.next, run) }),
                RunControlItem(
                    id: "run.stop", title: "Stop", icon: "stop", label: "Stop \(topic.name)", role: .secondary,
                    danger: true, perform: { stop(run) }),
                paused
                    ? RunControlItem(
                        id: "run.resume", title: "Resume", icon: "play", role: .secondary,
                        perform: { tap(.resume, run) })
                    : RunControlItem(
                        id: "run.pause", title: "Pause", icon: "pause", role: .secondary,
                        perform: { tap(.pause, run) }),
            ]
            if let skip = RunPresentation.skipTarget(run.state, steps: run.steps) {
                items.append(
                    RunControlItem(
                        id: "run.skip", title: "Skip \(skip.label)", icon: "forward.end", role: .overflow,
                        perform: { tap(.skip, run) }))
            }
            items.append(discardItem)
            return items
        }
        if let run, run.status == .finishing {
            guard let runId = UUID(uuidString: run.id) else { return [discardItem] }
            return [
                RunControlItem(
                    id: "run.addDetails", title: "Add details", icon: "pencil",
                    label: "Add details to \(topic.name)", role: .primary,
                    perform: { environment.router.open(.runDetails(link, runId: runId)) }),
                discardItem,
            ]
        }
        // An archived topic can't start a run (the server would refuse it).
        guard topic.status != .archived else { return [] }
        return [
            RunControlItem(
                id: "run.start", title: "Start", icon: "play", label: "Start \(topic.name)", role: .primary,
                perform: start)
        ]
    }

    private var discardItem: RunControlItem {
        RunControlItem(
            id: "run.discard", title: "Discard run…", icon: "trash", label: "Discard run", role: .destructive,
            perform: { confirmingDiscard = true })
    }

    // MARK: - Taps

    private func start() {
        let ref = TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
        let version = topic.currentVersion
        Task {
            if await environment.runActions.start(topic: ref, version: version) != nil { starts += 1 }
        }
    }

    /// Lap or Next: a tap with the selection haptic (§2.5).
    private func advance(_ type: RunTapType, _ run: LocalRun) {
        let expect = RunTapExpect(run)
        Task {
            if await environment.runActions.tap(type, run: run, expect: expect) != nil { advances += 1 }
        }
    }

    private func tap(_ type: RunTapType, _ run: LocalRun) {
        // Captured now: a second tap before the screen catches up targets what it showed.
        let expect = RunTapExpect(run)
        Task { await environment.runActions.tap(type, run: run, expect: expect) }
    }

    private func stop(_ run: LocalRun) {
        let expect = RunTapExpect(run)
        let (name, link, environment) = (topic.name, link, environment)
        Task {
            guard let outcome = await environment.runActions.stop(run: run, topicName: name, expect: expect) else {
                return
            }
            stops += 1
            switch outcome {
            case .details(let runId):
                guard let id = UUID(uuidString: runId) else { return }
                environment.router.replaceTop(with: .runDetails(link, runId: id))
            case .saved:
                showStopOutcome(outcome, ref: link, in: environment)
                dismiss()
            }
        }
    }

    private func discard() {
        guard let run else { return }
        Task {
            if await environment.runActions.discard(run: run) { dismiss() }
        }
    }
}

/// An open run, top to bottom (§2.1): the header (status, the total clock, the headline with the
/// segment's time, the alert line), then `controls`, then the step and lap table.
private struct OpenRunView<Controls: View>: View {
    let run: LocalRun
    @ViewBuilder let controls: Controls
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let now = environment.runTicker.serverNow
        let paused = run.status == .paused
        let total = RunPresentation.activeMs(run.state, now: now)
        let segment = RunPresentation.segmentMs(run.state, now: now)
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                QuickrBadge(
                    paused ? "Paused" : "Running", icon: paused ? .pause : .timer, tone: paused ? .warn : .accent
                )
                .accessibilityIdentifier("run.state")
                Spacer()
                if !run.queued.isEmpty {
                    Text("Saved on this device").font(.qr(.caption)).foregroundStyle(.qr.muted)
                }
            }
            VStack(spacing: 6) {
                RunDuration(ms: total, font: .qr(.sansSemiBold, size: 60, relativeTo: .largeTitle), ticking: !paused)
                    .foregroundStyle(paused ? Color.qr.muted : .qr.ink)
                    .accessibilityLabel("Total \(RunPresentation.spoken(total))")
                    .accessibilityIdentifier("run.total")
                if let headline = RunHeadline.text(run.state) {
                    HStack(spacing: 8) {
                        Text(headline).font(.qr(.callout)).foregroundStyle(.qr.ink)
                        RunDuration(ms: segment, font: .qr(.callout), ticking: !paused).foregroundStyle(.qr.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("run.segment")
                }
                // Phase 2: M1's `RunPresentation.alertLine` (nil while paused).
                RunAlertLine(text: nil)
            }
            .frame(maxWidth: .infinity)
            controls
            StepList(rows: RunPresentation.rows(run.state, steps: run.steps), liveMs: segment)
        }
        .runTicking(!paused)
    }
}

/// The step checklist (§11.2): done with its time, skipped, current (ticking) and upcoming; then
/// the laps.
private struct StepList: View {
    let rows: [RunPresentation.Row]
    /// The open segment's time, for the current row.
    let liveMs: Int

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    StepRow(row: row, ms: row.status == .current ? liveMs : row.ms)
                }
            }
            .qrCard()
        }
    }
}

private struct StepRow: View {
    let row: RunPresentation.Row
    let ms: Int?

    var body: some View {
        HStack(spacing: 12) {
            marker
            Text(row.label)
                .font(.qr(row.status == .current ? .callout : .body))
                .foregroundStyle(row.status == .skipped ? Color.qr.muted : .qr.ink)
                .strikethrough(row.status == .skipped)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let ms {
                RunDuration(ms: ms, font: .qr(.monoCaption))
                    .foregroundStyle(row.status == .current ? Color.qr.ink : .qr.muted)
            } else if row.status == .skipped {
                Text("Skipped").font(.qr(.caption)).foregroundStyle(.qr.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: QuickrMetrics.tapTarget)
        .background(row.status == .current ? Color.qr.accentSoft.opacity(0.6) : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(row.status.rawValue)
        .accessibilityIdentifier("run.step.\(row.id)")
    }

    /// "Shower, step 1, done, 4 minutes 12 seconds".
    private var spoken: String {
        var parts = [row.label]
        if let position = row.position { parts.append("step \(position)") }
        switch row.status {
        case .done: parts.append("done")
        case .skipped: parts.append("skipped")
        case .current: parts.append("now")
        case .upcoming: break
        }
        if let ms { parts.append(RunPresentation.spoken(ms)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var marker: some View {
        ZStack {
            switch row.status {
            case .done:
                Circle().fill(Color.qr.ok)
                QIcon.check.view(size: 12, weight: .heavy).foregroundStyle(.white)
            case .skipped:
                Circle().strokeBorder(Color.qr.lineStrong, lineWidth: 2)
                QIcon.skip.view(size: 10).foregroundStyle(.qr.muted)
            case .current:
                Circle().fill(Color.qr.accent)
                Circle().fill(Color.qr.onAccent).frame(width: 8, height: 8)
            case .upcoming:
                Circle().strokeBorder(
                    Color.qr.lineStrong, style: StrokeStyle(lineWidth: 2, dash: row.isLap ? [3, 2] : []))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
