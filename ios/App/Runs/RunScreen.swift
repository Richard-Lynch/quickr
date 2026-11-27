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
    @State private var confirmingRevert = false
    /// The topic's latest stop, while the store offers it "Resume" (`LocalStore.observeResumable`).
    @State private var resumable: ResumableRun?
    /// Moved when the Resume window closes, so the idle screen re-reads it then.
    @State private var windowClosed = Date.distantPast
    @State private var starts = 0
    @State private var advances = 0
    @State private var stops = 0

    private var link: TopicLinkRef { TopicLinkRef(id: topic.id) }

    var body: some View {
        let layout = RunControlsLayout(actions: actions)
        let busy = environment.runActions.isBusy(topic.id)
        let controls = RunControls(
            layout: layout, topic: topic.name, busy: busy, reopenTotalMs: resumable?.totalMs, perform: perform)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let run, run.isOpen {
                    OpenRunView(run: run) { controls }
                } else if let run, run.status == .finishing {
                    finishing(run, controls: controls)
                } else {
                    idle(controls: controls)
                }
            }
            .padding(16)
        }
        // The hero primary in the topic's tint and onTint (appearance.md §6.4, #286).
        .topicTheme(for: topic)
        .qrPaperBackground()
        .navigationTitle(topic.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !layout.overflow.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    RunOverflowMenu(actions: layout.overflow, topic: topic.name, busy: busy, perform: perform)
                }
            }
        }
        .alert("Discard this run?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep timing", role: .cancel) {}
        } message: {
            Text("Its times won’t be saved. This can’t be undone.")
        }
        .alert("Undo the resume?", isPresented: $confirmingRevert) {
            Button("Undo resume", role: .destructive) { revert() }
            Button("Keep timing", role: .cancel) {}
        } message: {
            Text("The run keeps its stop and its saved entry; the time since the resume isn’t saved.")
        }
        .task(id: ResumableKey(binding: environment.session?.binding, topicId: topic.id)) { await followResumable() }
        // An idle Resume is re-read when its window closes, rescheduled when the offset moves (§2.4).
        .onResumeWindowClose(resumable, offsetMs: environment.runTicker.offsetMs) { windowClosed = .now }
        .qrHaptic(.logged, trigger: starts)
        .qrHaptic(.selection, trigger: advances)
        .qrHaptic(.logged, trigger: stops)
    }

    // MARK: - States

    private func idle(controls: RunControls) -> some View {
        let steps = topic.timer?.steps ?? []
        return VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 6) {
                RunDuration(ms: 0, font: RunClockFont.total).runClockSize()
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
                font: RunClockFont.total
            )
            .runClockSize()
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

    /// The screen's actions in display order (§2.2): M1's actions for an open or finishing run
    /// (`RunActions.actions(for:)`: none while "Resuming…", §1.2 row 11; disabled while busy, row
    /// 14). Idle (rows 1–3, 13), Start, and "Resume · 1:44" (`reopen`, secondary) while the
    /// topic's latest stop is resumable (§2.4); none for an archived topic, whose start or
    /// reopen the server would refuse.
    private var actions: [RunAction] {
        if let run, run.isOpen || run.status == .finishing {
            // `now` only bounds the reopen window: the wall clock, so the panel doesn't follow the
            // ticker (OpenRunView does).
            return environment.runActions.actions(for: run, timer: run.timer, now: .now)
        }
        guard topic.status != .archived else { return [] }
        let start = RunAction(kind: .start, role: .primary, enabled: true)
        guard let resumable, resumable.isOffered(at: runNow) else { return [start] }
        return [start, resumable.action]
    }

    /// Now on the run clock (the store's server offset), the clock a stop's `endedAt` is on.
    private var runNow: Int {
        RunInstant.milliseconds(max(Date(), windowClosed)) + environment.runTicker.offsetMs
    }

    private func perform(_ action: RunAction) {
        switch action.kind {
        case .start: start()
        case .addDetails:
            guard let run, let runId = UUID(uuidString: run.id) else { return }
            environment.router.open(.runDetails(link, runId: runId))
        case .discard: confirmingDiscard = true
        case .reopen: reopen()
        case .revert: confirmingRevert = true
        case .next: advance(.next)
        case .lap: advance(.lap)
        case .skip: tap(.skip)
        case .pause: tap(.pause)
        case .resume: tap(.resume)
        case .stop: stop()
        }
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
    private func advance(_ type: RunTapType) {
        guard let run, run.isOpen else { return }
        let expect = RunTapExpect(run)
        Task {
            if await environment.runActions.tap(type, run: run, expect: expect) != nil { advances += 1 }
        }
    }

    private func tap(_ type: RunTapType) {
        guard let run, run.isOpen else { return }
        // Captured now: a second tap before the screen catches up targets what it showed.
        let expect = RunTapExpect(run)
        Task { await environment.runActions.tap(type, run: run, expect: expect) }
    }

    private func stop() {
        guard let run, run.isOpen else { return }
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
                showStopOutcome(outcome, run: run, ref: link, in: environment)
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

    /// Resume run (§2.4): reopens the latest stop by its entry (`timing.terminalId` names the
    /// stop); the screen then shows the open run, "Resuming…" until the ack when it came from the
    /// entry.
    private func reopen() {
        guard let resumable else { return }
        let actions = environment.runActions
        Task { await actions.reopen(runId: resumable.runId, topicId: resumable.topicId) }
    }

    /// Undo resume… (§1.2 row 10), after its confirmation: the reopen is undone and the stop kept,
    /// so the run is back in its entry. The screen stays: idle, with that stop's "Resume · 1:44"
    /// again while its window lasts (§2.4).
    private func revert() {
        guard let run else { return }
        let actions = environment.runActions
        Task { await actions.revert(run: run) }
    }

    /// The topic's latest stop while the store offers it "Resume" (M2's `observeResumable`).
    private func followResumable() async {
        guard let session = environment.session, let store = session.store else { return }
        do {
            for try await latest in store.observeResumable(topicId: topic.id, refresh: session.refresh.stream()) {
                resumable = latest
            }
        } catch {
            // the store closed: the next binding observes again
        }
    }

    private struct ResumableKey: Hashable {
        var binding: AppSession.Binding?
        var topicId: UUID
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
                // "Resuming…" while a reopen from the entry waits for its ack (§2.4: no controls).
                QuickrBadge(
                    RunHeaderText.state(resuming: run.resuming, paused: paused), icon: paused ? .pause : .timer,
                    tone: paused ? .warn : .accent
                )
                .accessibilityIdentifier("run.state")
                Spacer()
                if !run.queued.isEmpty {
                    Text("Saved on this device").font(.qr(.caption)).foregroundStyle(.qr.muted)
                }
            }
            VStack(spacing: 6) {
                RunDuration(ms: total, font: RunClockFont.total, ticking: !paused)
                    .runClockSize()
                    .foregroundStyle(paused ? Color.qr.muted : .qr.ink)
                    .accessibilityLabel("Total \(RunPresentation.spoken(total))")
                    .accessibilityIdentifier("run.total")
                if let headline = RunHeadline.text(run) {
                    SegmentClock(label: headline, ms: segment, ticking: !paused, paused: paused)
                }
                RunAlertLine(
                    fired: environment.runAlerts.label(runId: run.id),
                    next: RunPresentation.alertLine(run.state, timer: run.timer, now: RunInstant.date(now)))
            }
            .frame(maxWidth: .infinity)
            controls
            StepList(
                rows: RunPresentation.rows(run.state, steps: run.steps), liveMs: segment,
                lapTypes: RunHeaderText.lapTypeBadges(run.state, timer: run.timer))
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
    /// The typed lap rows' type labels, by row id (§2.1's lap-type badge).
    var lapTypes: [String: String] = [:]

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    StepRow(row: row, ms: row.status == .current ? liveMs : row.ms, lapType: lapTypes[row.id])
                }
            }
            .qrCard()
        }
    }
}

private struct StepRow: View {
    let row: RunPresentation.Row
    let ms: Int?
    /// A typed lap's type label ("Rest"), shown as a neutral badge.
    var lapType: String?

    var body: some View {
        HStack(spacing: 12) {
            marker
            Text(row.label)
                .font(.qr(row.status == .current ? .callout : .body))
                .foregroundStyle(row.status == .skipped ? Color.qr.muted : .qr.ink)
                .strikethrough(row.status == .skipped)
            if let lapType { QuickrBadge(lapType, tone: .neutral) }
            Spacer(minLength: 0)
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
