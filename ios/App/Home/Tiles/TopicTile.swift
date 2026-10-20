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
/// `quick.number` and `quick.check`.
struct TopicTile: View {
    let topic: ViewTopic
    /// HOME's ticking clock, shared by every tile so the list agrees on what is due.
    let now: Date
    /// Taps outside the controls: the topic screen.
    let onOpen: () -> Void
    /// The Log block: the record screen.
    let onRecord: () -> Void

    @Environment(AppEnvironment.self) private var environment

    private let text = TopicText()

    var body: some View {
        // From the app-wide cache, so a tile the lazy list rebuilds has its model and last value
        // at once (QuickLogModels); the task below keeps them current.
        let model = quickTopic.map(environment.quickLogModels.model(for:))
        let topic = topic.topic
        // Recomputed from the schedule and the last entry (queued ones too), so a log clears
        // "Due now" at once, even offline, like the PWA's `dueAfterLogging`.
        let due = DueView(due: TopicListing.due(of: topic, at: now) ?? topic.due, now: now)
        TileView(
            title: topic.name, isDue: due.tone == .due || due.tone == .overdue, onOpen: onOpen,
            onLog: topic.status == .archived ? nil : onRecord
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
        if let quick = quickTopic?.quick, let last, let answer = text.answer(last, for: quick.question) {
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
        guard let session = environment.session, let store = session.store, topic.topic.entryCount > 0 else {
            models.update(quickTopic, last: nil, from: scope)
            return
        }
        do {
            for try await entries in store.observeEntries(
                topicId: quickTopic.id, limit: 1, refresh: session.refresh.stream())
            {
                models.update(
                    quickTopic, last: entries.first?.entry.answers[quickTopic.quick.question.key], from: scope)
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
        }
    }
}
