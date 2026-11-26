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
            if state == .idle, let reopen = Self.reopen(topic, now: serverNow) {
                reopenButton(reopen, slug: topic.slug)
            }
        }
        .accessibilityIdentifier("tile.\(topic.slug)")
    }

    /// An idle timed tile's "Resume · 1:44" (active-surfaces.md §3.3, §1.2 row 2): the latest
    /// entry's run reopened, for OQ-1's 15 minutes after its stop.
    struct Reopen {
        /// `reopen(target:)`, the target being the latest local entry's `timing.terminalId`.
        var action: RunAction
        /// The stopped run's total, for the title.
        var totalMs: Int
        var perform: () -> Void
    }

    /// Seam, pending M1: needs the latest local entry's `timing.terminalId` (timers2.md §3.3; not
    /// in `Timing` yet), `RunPresentation.resumable(entry, now:)` over it, and the reopen write
    /// (I1-WRITES). Until then nothing is resumable and the tile shows no Resume (§8.2).
    static func reopen(_ topic: Topic, now: Date) -> Reopen? { nil }

    private func reopenButton(_ reopen: Reopen, slug: String) -> some View {
        let label = CardLabel(reopen.action, topic: topic.topic.name)
        return Button(action: reopen.perform) {
            Label("Resume · \(DurationFormat.format(reopen.totalMs))", systemImage: label.systemImage)
        }
        .buttonStyle(.qr(.ghost, size: .small))
        .disabled(!reopen.action.enabled)
        .accessibilityLabel(label.spoken)
        .accessibilityIdentifier("tile.\(slug).reopen")
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
