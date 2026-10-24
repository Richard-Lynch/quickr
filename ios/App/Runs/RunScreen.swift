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

/// The run screen's body for `topic`: its open run's clocks and controls, a finishing run's Add
/// details, or Start. Also the record screen's, for a timed topic.
struct RunPanel: View {
    let topic: Topic
    let run: LocalRun?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var starts = 0

    private var link: TopicLinkRef { TopicLinkRef(id: topic.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let run, run.isOpen {
                    OpenRunView(run: run)
                } else if let run, run.status == .finishing {
                    finishing(run)
                } else {
                    idle
                }
            }
            .padding(16)
        }
        .qrPaperBackground()
        .safeAreaInset(edge: .bottom) { bar }
        .navigationTitle(topic.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let run, run.isOpen || run.status == .finishing {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Discard run…", role: .destructive) { confirmingDiscard = true }
                            .accessibilityIdentifier("run.discard")
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("run.menu")
                }
            }
        }
        .alert("Discard this run?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep timing", role: .cancel) {}
        } message: {
            Text("Its times won’t be saved. This can’t be undone.")
        }
        .qrHaptic(.logged, trigger: starts)
    }

    // MARK: - States

    private var idle: some View {
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
            if !steps.isEmpty {
                StepList(rows: RunPresentation.rows(steps: steps), liveMs: 0)
            }
            if topic.status == .archived {
                Text("This topic is archived. Unarchive it to time it.")
                    .font(.qr(.subheadline))
                    .foregroundStyle(QuickrTone.warn.foreground)
                    .accessibilityIdentifier("run.archived")
            }
        }
    }

    private func finishing(_ run: LocalRun) -> some View {
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
            StepList(rows: RunPresentation.rows(run.state, steps: run.steps), liveMs: 0)
        }
    }

    // MARK: - The bar

    @ViewBuilder private var bar: some View {
        HStack(spacing: 10) {
            if let run, run.isOpen {
                let primary = RunPresentation.primary(run.state, steps: run.steps)
                if primary.isNext {
                    Button {
                        stop(run)
                    } label: {
                        Label("Stop", systemImage: "stop")
                    }
                    .buttonStyle(.qr(.secondary, size: .large))
                    .accessibilityIdentifier("run.stop")
                }
                Button {
                    if primary.isNext { tap(.next, run) } else { stop(run) }
                } label: {
                    Label(primary.title, systemImage: primary.isNext ? "chevron.right" : "stop")
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.qr(.primary, size: .large))
                .accessibilityIdentifier("run.primary")
            } else if let run, run.status == .finishing, let runId = UUID(uuidString: run.id) {
                Button {
                    environment.router.open(.runDetails(link, runId: runId))
                } label: {
                    Label("Add details", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.qr(.primary, size: .large))
                .accessibilityIdentifier("run.addDetails")
            } else if topic.status != .archived {
                Button {
                    start()
                } label: {
                    Label("Start", systemImage: "play").frame(maxWidth: .infinity)
                }
                .buttonStyle(.qr(.primary, size: .large))
                .accessibilityIdentifier("run.start")
            }
        }
        .disabled(environment.runActions.isBusy(topic.id))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.qr.paper)
    }

    // MARK: - Taps

    private func start() {
        let ref = TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
        let version = topic.currentVersion
        Task {
            if await environment.runActions.start(topic: ref, version: version) != nil { starts += 1 }
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

/// An open run: the status, the total and segment clocks, the step list, and Lap, Skip and
/// Pause or Resume.
private struct OpenRunView: View {
    let run: LocalRun
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let now = environment.runTicker.serverNow
        let paused = run.status == .paused
        let total = RunPresentation.activeMs(run.state, now: now)
        let segment = RunPresentation.segmentMs(run.state, now: now)
        let skip = RunPresentation.skipTarget(run.state, steps: run.steps)
        let expect = RunTapExpect(run)
        let busy = environment.runActions.isBusy(run.topicId)
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
                if let open = run.state.open {
                    HStack(spacing: 8) {
                        Text(open.label).font(.qr(.callout)).foregroundStyle(.qr.ink)
                        RunDuration(ms: segment, font: .qr(.callout), ticking: !paused).foregroundStyle(.qr.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("run.segment")
                }
            }
            .frame(maxWidth: .infinity)
            StepList(rows: RunPresentation.rows(run.state, steps: run.steps), liveMs: segment)
            // Side by side; stacked when the labels don't fit (large text, a long step name).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { controls(skip: skip, expect: expect, busy: busy, paused: paused) }
                VStack(spacing: 8) { controls(skip: skip, expect: expect, busy: busy, paused: paused) }
            }
        }
        .runTicking(!paused)
    }

    @ViewBuilder
    private func controls(
        skip: RunPresentation.SkipTarget?, expect: RunTapExpect, busy: Bool, paused: Bool
    ) -> some View {
        control("Lap", icon: "flag", id: "run.lap", label: "Lap") {
            tap(.lap, expect)
        }
        .disabled(busy || run.state.open == nil)
        control(
            skip.map { "Skip \($0.label)" } ?? "Skip", icon: "forward.end", id: "run.skip",
            label: skipLabel(skip)
        ) {
            tap(.skip, expect)
        }
        .disabled(busy || skip == nil)
        control(
            paused ? "Resume" : "Pause", icon: paused ? "play" : "pause",
            id: paused ? "run.resume" : "run.pause", label: paused ? "Resume" : "Pause"
        ) {
            tap(paused ? .resume : .pause, expect)
        }
        .disabled(busy)
    }

    /// "Skip Breakfast (step 3)".
    private func skipLabel(_ skip: RunPresentation.SkipTarget?) -> String {
        guard let skip else { return "Skip" }
        guard let index = run.steps?.firstIndex(where: { $0.key == skip.key }) else { return "Skip \(skip.label)" }
        return "Skip \(skip.label) (step \(index + 1))"
    }

    private func control(
        _ title: String, icon: String, id: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.qr(.secondary))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func tap(_ type: RunTapType, _ expect: RunTapExpect) {
        Task { await environment.runActions.tap(type, run: run, expect: expect) }
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
