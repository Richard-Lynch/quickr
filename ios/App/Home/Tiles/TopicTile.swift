import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// One topic on the home screen (the PWA's `TopicTile`): its name, due badge and "Last …" line,
/// the quick-log area when the topic has one (chips, or a stepper with ✓), and the Log block.
/// HOME lays the tiles out and navigates; the tile logs by itself through `AppEnvironment`'s
/// session, toasts and drafts.
///
/// Accessibility identifiers: `tile.<slug>` on the tile; inside it, `chip.<value>`,
/// `quick.number` and `quick.check`. A topic with an open run is an `ActiveTopicCard` instead.
struct TopicTile: View {
    let topic: ViewTopic
    /// HOME's ticking device clock, for "Last … ago".
    let now: Date
    /// `now` on the server's clock (sync-protocol.md §10), shared by every tile so the list
    /// agrees on what is due.
    let serverNow: Date
    /// Taps outside the controls: the topic screen.
    let onOpen: () -> Void
    /// The Log block: the record screen.
    let onRecord: () -> Void
    /// The run the home model has for the topic: its open run, else its finishing one.
    var run: LocalRun?

    @Environment(AppEnvironment.self) private var environment
    /// Counts the Starts this tile made, for the haptic.
    @State private var starts = 0
    /// A timed topic's latest stop, while the store offers it "Resume" (`observeResumable`).
    @State private var resumable: ResumableRun?

    private let text = TopicText()

    var body: some View {
        let state = RunTileState(timed: topic.topic.timer != nil, run: run?.status)
        Group {
            if case .open = state, let run {
                // "Active now" (active-surfaces.md §3.2): the run's own card, opening its run screen.
                let link = TopicLinkRef(id: topic.topic.id)
                ActiveTopicCard(topic: topic, run: run, onOpen: { environment.router.open(.run(link)) })
                    .topicTheme(for: topic.topic)
            } else if state.isTimed {
                timedTile(state)
            } else {
                plainTile
            }
        }
        // Here, not on the idle tile: by the time a Start returns, the tile may be the card.
        .qrHaptic(.logged, trigger: starts)
        .task(id: ResumableKey(binding: environment.session?.binding, topicId: topic.topic.id, timed: state.isTimed)) {
            await followResumable(timed: state.isTimed)
        }
    }

    /// A timed topic without an open run (timers.md §11.1, §11.2): never a one-tap log or quick
    /// answers. Idle shows Start; a finishing run "Add details", keeping its due state. (An open
    /// run is an `ActiveTopicCard`.)
    private func timedTile(_ state: RunTileState) -> some View {
        let topic = topic.topic
        let due = DueView(due: TopicListing.due(of: topic, at: serverNow) ?? topic.due, now: serverNow)
        // With a run, the tile opens its run screen (§11.2); idle, the topic.
        let link = TopicLinkRef(id: topic.id)
        return TileView(
            title: topic.name, isDue: due.tone == .due || due.tone == .overdue,
            onOpen: state == .idle ? onOpen : { environment.router.open(.run(link)) }, action: runAction(state)
        ) {
            VStack(alignment: .leading, spacing: 4) {
                if let run, state != .idle {
                    RunStatusLine(run: run)
                    if state == .finishing, due.kind != .none { DueBadge(due) }
                } else {
                    meta(due, last: nil)
                }
            }
        } quick: {
            // Interactive, so under the meta line in the quick slot (the meta passes taps through).
            if state == .idle, topic.status != .archived, let resumable {
                let offset = environment.runTicker.offsetMs
                // Re-read when the window closes; the schedule follows the offset (observed).
                TimelineView(.explicit([resumable.closes(offsetMs: offset)])) { _ in
                    if resumable.isOffered(at: RunInstant.milliseconds(Date()) + offset) {
                        reopenButton(resumable, slug: topic.slug)
                    }
                }
            }
        }
        .accessibilityIdentifier("tile.\(topic.slug)")
    }

    /// An idle timed tile's "Resume · 1:44" (active-surfaces.md §3.3, §1.2 rows 2 and 13): the
    /// latest local entry's run reopened (its `timing.terminalId` names the stop), for OQ-1's 15
    /// minutes after the stop, on the run clock (the clock the stop was stamped on). The window
    /// is read again the moment it closes and whenever the store's server offset moves.
    private func reopenButton(_ resumable: ResumableRun, slug: String) -> some View {
        let action = resumable.action
        let actions = environment.runActions
        return Button {
            Task { await actions.reopen(runId: resumable.runId, topicId: resumable.topicId) }
        } label: {
            Label(RunHeaderText.reopenTitle(totalMs: resumable.totalMs), systemImage: action.systemImage)
        }
        .buttonStyle(.qr(.ghost, size: .small))
        .disabled(!action.enabled || actions.isBusy(topic.topic.id))
        .accessibilityLabel(action.spokenTitle(topic: topic.topic.name))
        .accessibilityIdentifier("tile.\(slug).reopen")
    }

    /// The topic's latest stop while the store offers it "Resume"; nothing for an untimed topic.
    private func followResumable(timed: Bool) async {
        guard timed, let session = environment.session, let store = session.store else {
            resumable = nil
            return
        }
        do {
            for try await latest in store.observeResumable(topicId: topic.topic.id, refresh: session.refresh.stream()) {
                resumable = latest
            }
        } catch {
            // The observation ends with its store (a reset or a switch); the next binding restarts it.
        }
    }

    private struct ResumableKey: Hashable {
        var binding: AppSession.Binding?
        var topicId: UUID
        var timed: Bool
    }

    /// The block: Start, or Add details. None for an archived topic with no run (a start would be
    /// refused).
    private func runAction(_ state: RunTileState) -> TileAction? {
        let topic = topic.topic
        let ref = TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
        let link = TopicLinkRef(id: topic.id)
        let actions = environment.runActions
        let id = "tile.\(topic.slug).run"
        switch state {
        case .untimed:
            return nil
        case .idle:
            guard topic.status != .archived else { return nil }
            return TileAction(
                icon: .play, title: "Start", label: "Start \(topic.name)", identifier: id,
                disabled: actions.isBusy(topic.id)
            ) {
                Task {
                    if await actions.start(topic: ref, version: topic.currentVersion) != nil { starts += 1 }
                }
            }
        case .finishing:
            guard let run, let runId = UUID(uuidString: run.id) else { return nil }
            return TileAction(
                icon: .edit, title: "Add details", label: "Add details to \(topic.name)", identifier: id, loud: false
            ) {
                environment.router.open(.runDetails(link, runId: runId))
            }
        case .open:
            return nil  // an ActiveTopicCard, with its own controls
        }
    }

    @ViewBuilder private var plainTile: some View {
        // From the app-wide cache, so a tile the lazy list rebuilds has its model and last value
        // at once (QuickLogModels); the task below keeps them current.
        let model = quickTopic.map(environment.quickLogModels.model(for:))
        let topic = topic.topic
        // Recomputed from the schedule and the last entry (queued ones too), so a log clears
        // "Due now" at once, even offline, like the PWA's `dueAfterLogging`.
        let due = DueView(due: TopicListing.due(of: topic, at: serverNow) ?? topic.due, now: serverNow)
        TileView(
            title: topic.name, isDue: due.tone == .due || due.tone == .overdue, onOpen: onOpen,
            onLog: logAction(model)
        ) {
            meta(due, last: model?.last)
        } quick: {
            if let model { QuickLogArea(model: model) }
        }
        .accessibilityIdentifier("tile.\(topic.slug)")
        .task(id: observationKey) {
            await follow()
        }
    }

    /// The Log block: none for an archived topic; a single topic (no questions) logs at once, with
    /// the usual Undo toast (offline too, through the outbox); any other opens the record screen.
    private func logAction(_ model: QuickLogModel?) -> (() -> Void)? {
        guard topic.topic.status != .archived else { return nil }
        // Decided by the topic's current questions, not the cached model (updated later, by
        // `follow()`): one that just gained questions opens the form, one that just lost them logs.
        if let model, let quickTopic, case .single = quickTopic.quick {
            return {
                if model.topic != quickTopic { model.topic = quickTopic }
                Task { await model.logSingle() }
            }
        }
        return onRecord
    }

    private var quickTopic: QuickLogTopic? {
        let topic = topic.topic
        guard topic.status != .archived, let quick = QuickLog(questions: topic.questions) else { return nil }
        return QuickLogTopic(
            id: topic.id, slug: topic.slug, name: topic.name, version: topic.currentVersion, quick: quick)
    }

    /// Restarts the observation when the store, the quick-log or "has entries" changes.
    private var observationKey: ObservationKey {
        ObservationKey(
            binding: environment.session?.binding, quick: quickTopic, hasEntries: topic.topic.entryCount > 0)
    }

    private func meta(_ due: DueView, last: AnswerValue?) -> some View {
        let archived = topic.topic.status == .archived
        return VStack(alignment: .leading, spacing: 4) {
            if due.kind != .none || archived {
                HStack(spacing: 6) {
                    DueBadge(due)
                    if archived { QuickrBadge("Archived", icon: .archive, tone: .warn) }
                }
            }
            lastLine(last)
        }
    }

    /// `last`: the latest entry's answer to the quick question (quick-log topics only, like the PWA).
    private func lastLine(_ last: AnswerValue?) -> Text {
        let topic = topic.topic
        guard topic.entryCount > 0 else { return Text("No entries yet") }
        let when = text.relative(topic.lastCapturedAt, now: now)
        if let question = quickTopic?.quick.question, let last, let answer = text.answer(last, for: question) {
            return Text("Last \(Text(answer).fontWeight(.semibold).foregroundStyle(.qr.inkSoft)) · \(when)")
        }
        return Text("\(text.count(topic.entryCount, "entry", "entries")) · \(when)")
    }

    /// Keeps the cached model in step with the topic, and its last value with the store.
    private func follow() async {
        guard let quickTopic else { return }
        let models = environment.quickLogModels
        // The store this observation reads; updates are dropped once another is active.
        let scope = environment.entryWriter.scope
        // A single topic has no question, so no last answer to follow.
        guard let key = quickTopic.quick.question?.key, let session = environment.session,
            let store = session.store, topic.topic.entryCount > 0
        else {
            models.update(quickTopic, last: nil, from: scope)
            return
        }
        do {
            for try await entries in store.observeEntries(
                topicId: quickTopic.id, limit: 1, refresh: session.refresh.stream())
            {
                models.update(
                    quickTopic, last: entries.first?.entry.answers[key], from: scope)
            }
        } catch {
            // The observation ends with its store (a reset or a switch); the next binding restarts it.
        }
    }

    private struct ObservationKey: Hashable {
        var binding: AppSession.Binding?
        var quick: QuickLogTopic?
        var hasEntries: Bool
    }
}

/// The tile's quick-log controls over its model.
private struct QuickLogArea: View {
    let model: QuickLogModel

    static func rule(_ question: Question) -> NumberStepRule {
        let rules = question.numericRules
        return NumberStepRule(
            integer: rules?.isInteger ?? true, min: rules?.min, max: rules?.max, decimals: rules?.decimals)
    }

    var body: some View {
        switch model.topic.quick {
        case .chips(let question, let options):
            QuickChipGrid(
                options: options.map { ChipOption($0.value, label: $0.label) }, last: model.lastOption,
                label: "Log \(question.label)", busy: model.busyOption, flash: model.flash
            ) { chip in
                guard let option = options.first(where: { $0.value == chip.value }) else { return }
                Task { await model.pick(option) }
            }
        case .number(let question):
            @Bindable var model = model
            QuickNumberRow(
                label: model.numberLabel, text: $model.numberText, rule: Self.rule(question),
                unit: question.numericRules?.unit.flatMap { $0.isEmpty ? nil : $0 },
                isBusy: model.isLoggingNumber, error: model.numberError
            ) {
                Task { await model.logNumber() }
            }
        case .single:
            EmptyView()  // the Log block logs it
        }
    }
}
