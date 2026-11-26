import Foundation

/// What a widget shows of one topic, read once from the store (widgets render snapshots; they
/// don't observe). Plain values, so the timeline provider, the app's reload check and the views
/// share it, and tests build it directly.
public struct WidgetTopic: Sendable, Hashable, Identifiable {
    public var topic: Topic
    /// How it logs in one tap (chips or "✓ last"), or nil when it needs the record screen.
    public var quick: QuickLog?
    /// The latest entry's answer to the quick question (pending ones included: they're the user's).
    public var lastAnswer: AnswerValue?
    /// Entries this device has logged that haven't reached the server yet ("queued").
    public var queued: Int
    /// Entries the server refused (the sync sheet fixes them).
    public var failed: Int
    /// The store this was read from: a widget's buttons log only while it is still the active one.
    /// Nil for a sample (the app's widget gallery): its buttons open the record screen.
    public var scope: EntryScope?
    /// Server time minus device time, in seconds: the store's measured skew (sync-protocol.md
    /// §10, `skew_ms`). Due state is the server's, at device time plus this.
    public var skew: TimeInterval
    /// The topic has an open run (running or paused) in the store's local view: it isn't counted
    /// as due (timers.md §11.1).
    public var hasOpenRun: Bool
    /// The run a timed widget shows (timers.md §11.3): the topic's open run, else its newest
    /// finishing one, as the Live Activity's content state (`steps_unknown` when the pinned
    /// version's steps aren't stored). Nil for none.
    public var run: RunActivityState?
    /// Whether the open run's pinned timer has lap types (`RunWrites.autoTap` reads that one, not
    /// the topic's current timer); nil without an open run.
    public var runLapTyped: Bool?
    /// What the open run's Auto press does (`RunWrites.autoTap`, active-surfaces.md §5.3), so the
    /// one-button surfaces say what the press will do; nil without an open run. The content state
    /// alone can't tell it: on a timer without lap types a lap opened mid-steps carries no
    /// `next_label`, yet the press is Next while a step remains.
    public var runAuto: WidgetRunButton?
    /// This build is too old for the store's server (client-versions.md §4.1): the widget shows a
    /// small "Update quickR" line, and its taps are kept on the iPhone until the update.
    public var updateRequired: Bool

    public var id: UUID { topic.id }

    public init(
        topic: Topic, quick: QuickLog?, lastAnswer: AnswerValue?, queued: Int = 0, failed: Int = 0,
        scope: EntryScope? = nil, skew: TimeInterval = 0, hasOpenRun: Bool = false, run: RunActivityState? = nil,
        runLapTyped: Bool? = nil, runAuto: WidgetRunButton? = nil, updateRequired: Bool = false
    ) {
        self.topic = topic
        self.quick = quick
        self.lastAnswer = lastAnswer
        self.queued = queued
        self.failed = failed
        self.scope = scope
        self.skew = skew
        self.hasOpenRun = hasOpenRun
        self.run = run
        self.runLapTyped = runLapTyped
        self.runAuto = runAuto
        self.updateRequired = updateRequired
    }

    /// What ✓ shows and logs for a number topic, the same value for both: the last one while the
    /// question still accepts it, else its start (the minimum), like the tile's stepper; nil when
    /// there's neither.
    public var checkAnswer: AnswerValue? {
        guard case .number(let question) = quick,
            let number = Double(QuickLog.initialText(for: question, last: lastAnswer))
        else { return nil }
        if case .int = question.kind, number == number.rounded(), abs(number) < Double(Int.max) {
            return .int(Int(number))
        }
        return .double(number)
    }

    /// The due state at device time `date` (timeline entries are rendered ahead of time): the
    /// server's, at `serverTime(date)`. Its times are the server's ("Next 08:00" is 08:00), so
    /// show it against `serverTime(date)` too (`DueView(due:now:)`).
    public func due(at date: Date) -> DueStatus? { TopicListing.due(of: topic, at: serverTime(date)) }

    /// The due pill at device time `date`: none while the topic has an open run, which shows
    /// "Running" instead of its due state (timers.md §11.1).
    public func dueView(at date: Date) -> DueView {
        hasOpenRun ? DueView(tone: .none, kind: .none) : DueView(due: due(at: date), now: serverTime(date))
    }

    /// Whether it counts as due at device time `date`: `TopicListing.countsAsDue`, the one rule
    /// behind every due count (active, due now, no open run).
    public func countsAsDue(at date: Date) -> Bool {
        let now = serverTime(date)
        return TopicListing.countsAsDue(
            TopicListing.Item(value: (), topic: topic, due: TopicListing.due(of: topic, at: now)), now: now,
            openRuns: hasOpenRun ? [topic.id] : TopicListing.noOpenRuns)
    }

    /// Device time `date` on the server's clock (`date + skew`), the "now" of due state.
    public func serverTime(_ date: Date) -> Date { ServerClock(skew: skew).now(at: date) }

    /// Where a tap on the widget goes: the topic's record screen by id, naming the store it was
    /// read from (`quickr://t/{topic_id}/record?scope=…`), so a widget left over from another
    /// server or store is refused, not opened on a same-slug topic (notifications.md §7.5). A
    /// sample (no store) links by slug.
    public var recordURL: URL {
        guard let scope else {
            return DeepLink.url(for: .record(TopicLinkRef(topic.slug) ?? TopicLinkRef(id: topic.id)))
        }
        return DeepLink.url(for: .record(TopicLinkRef(id: topic.id)), scope: scope)
    }
}

/// A timed widget's button (timers.md §11.3): a start, or one tap on the run it shows.
public enum WidgetRunButton: String, Sendable, Hashable, CaseIterable {
    case start, next, lap, stop

    public var title: String {
        switch self {
        case .start: "Start"
        case .next: "Next"
        case .lap: "Lap"
        case .stop: "Stop"
        }
    }
}

extension WidgetTopic {
    /// What a timed widget shows, as the home tile decides it: Start, the open run, or "Add
    /// details"; `.untimed` for the quick-log widget.
    public var runTile: RunTileState { RunTileState(timed: topic.timer != nil, run: run?.runStatus) }

    /// The shown run's label, timers and buttons, as its Live Activity has them.
    public var runDisplay: RunActivityDisplay? { run.map { RunActivityDisplay(state: $0, topicName: topic.name) } }

    /// The timer declares lap types (active-surfaces.md §5.3, #222): its one-button Auto is the
    /// on-screen primary, never Stop, as M1's `RunWrites.auto` presses it. An open run's pinned
    /// timer decides (`runLapTyped`, what the press reads, even after an edit of the topic);
    /// otherwise the topic's current one, which a Start pins.
    public var isLapTyped: Bool { runLapTyped ?? !(topic.timer?.laps.isEmpty ?? true) }

    /// The buttons (timers.md §11.3, active-surfaces.md §5.1): idle, Start (none for an archived
    /// topic); open, the primary (Lap whenever a lap or the last step is open, else Next: §4.1,
    /// as the Live Activity has it) and Stop; `compact` (the small widget, the Control), the one
    /// Auto button of §5.3. A finishing run has none: it links to "Add details".
    public func runButtons(compact: Bool) -> [WidgetRunButton] {
        switch runTile {
        case .untimed, .finishing:
            return []
        case .idle:
            return topic.status == .archived ? [] : [.start]
        case .open:
            guard let display = runDisplay else { return [] }
            if compact, let runAuto { return [runAuto] }
            return Self.runButtons(of: display, compact: compact, lapTyped: isLapTyped)
        }
    }

    /// An open run's buttons from what its Live Activity shows: `display.buttons.first` is the
    /// primary (the §4.1 rule lives in `RunActivityDisplay`), Stop beside it; `compact`, the one
    /// Auto button (`autoButton`).
    public static func runButtons(of display: RunActivityDisplay, compact: Bool, lapTyped: Bool) -> [WidgetRunButton] {
        let primary: WidgetRunButton = display.buttons.first == .lap ? .lap : .next
        if compact { return [autoButton(primary: primary, lapTyped: lapTyped)] }
        return [primary, .stop]
    }

    /// The one-button rule (§5.3) from the content state alone, for a topic built without the
    /// store (`runAuto` nil: the widget gallery, tests): a lap-typed timer's Auto is its primary
    /// (Lap stays Lap); on any other timer v1's Auto (timers.md §11.1), Next while the primary is
    /// Next (a named step follows, or the steps aren't known), else Stop. A lap opened mid-steps on
    /// such a timer presses Next, which only the run knows: the reader sets `runAuto` for it.
    public static func autoButton(primary: WidgetRunButton, lapTyped: Bool) -> WidgetRunButton {
        if lapTyped { return primary }
        return primary == .next ? .next : .stop
    }

    /// A button's title (§1.3): "Start", "Next: Breakfast" (a plain "Next" while the steps aren't
    /// known), "Lap", or "Lap → Rest" when the lap it opens has a type (the display's `nextLabel`
    /// during a lap on a lap-typed timer), "Stop".
    public func runButtonTitle(_ button: WidgetRunButton) -> String {
        Self.runButtonTitle(button, of: runDisplay, lapTyped: isLapTyped)
    }

    public static func runButtonTitle(
        _ button: WidgetRunButton, of display: RunActivityDisplay?, lapTyped: Bool
    ) -> String {
        switch button {
        case .start: "Start"
        case .next: display?.nextLabel.map { "Next: \($0)" } ?? "Next"
        case .lap: lapNextLabel(of: display, lapTyped: lapTyped).map { "Lap → \($0)" } ?? "Lap"
        case .stop: "Stop"
        }
    }

    /// What VoiceOver says for `button` (§1.3): "Start Dishwasher", "Next: Breakfast", "Lap, then
    /// Rest", "Stop Dishwasher".
    public func runButtonLabel(_ button: WidgetRunButton) -> String {
        Self.runButtonLabel(button, of: runDisplay, lapTyped: isLapTyped, topicName: topic.name)
    }

    public static func runButtonLabel(
        _ button: WidgetRunButton, of display: RunActivityDisplay?, lapTyped: Bool, topicName: String
    ) -> String {
        switch button {
        case .start: "Start \(topicName)"
        case .next: runButtonTitle(.next, of: display, lapTyped: lapTyped)
        case .lap: lapNextLabel(of: display, lapTyped: lapTyped).map { "Lap, then \($0)" } ?? "Lap"
        case .stop: "Stop \(topicName)"
        }
    }

    /// The lap type a Lap opens ("Rest"): on a lap-typed timer, the display's `nextLabel` while
    /// its primary is Lap (M1 sets `next_label` during typed laps). Without lap types a lap's
    /// `nextLabel` is a step still to come, which Lap doesn't open; a step's belongs to Next.
    private static func lapNextLabel(of display: RunActivityDisplay?, lapTyped: Bool) -> String? {
        guard lapTyped, let display, display.buttons.first == .lap else { return nil }
        return display.nextLabel
    }

    /// Where a tap on a timed widget goes: the run screen, or for a finishing run its answers
    /// form ("Add details"), naming the store like `recordURL`.
    public var runURL: URL {
        let ref = TopicLinkRef(id: topic.id)
        let route: Route
        if runTile == .finishing, let runId = run.flatMap({ UUID(uuidString: $0.runId) }) {
            route = .runDetails(ref, runId: runId)
        } else {
            route = .run(ref)
        }
        guard let scope else { return DeepLink.url(for: route) }
        return DeepLink.url(for: route, scope: scope)
    }

    /// `topics` in the home list's due-first order at device time `date` (a timeline entry's own
    /// order), in server time: they come from one store, so they share its skew.
    public static func dueFirst(_ topics: [WidgetTopic], at date: Date) -> [WidgetTopic] {
        let now = ServerClock(skew: topics.first?.skew ?? 0).now(at: date)
        return TopicListing.list(topics, topic: \.topic, now: now, status: .active, sort: .due, query: "").map(\.value)
    }
}
