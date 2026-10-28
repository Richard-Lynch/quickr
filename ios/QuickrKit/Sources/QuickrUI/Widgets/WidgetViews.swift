#if os(iOS)
import AppIntents
import QuickrCore
import SwiftUI
import WidgetKit

/// What a widget's controls run: the intent that logs an option, or the "✓ last" value, without
/// opening the app (INTENTS' fully specified `LogEntryIntent`s). Nil, or nil for a control, falls
/// back to opening the record screen (the gallery, and topics that need the form).
public struct WidgetActions {
    public var option: (EnumOption) -> (any AppIntent)?
    public var number: (AnswerValue) -> (any AppIntent)?
    /// A single topic's "Log it" (no questions).
    public var single: () -> (any AppIntent)?
    /// A timed topic's Start, Next, Lap or Stop (timers.md §11.3); nil opens the run screen.
    public var run: (WidgetRunButton) -> (any AppIntent)?

    public init(
        option: @escaping (EnumOption) -> (any AppIntent)?, number: @escaping (AnswerValue) -> (any AppIntent)?,
        single: @escaping () -> (any AppIntent)? = { nil },
        run: @escaping (WidgetRunButton) -> (any AppIntent)? = { _ in nil }
    ) {
        self.option = option
        self.number = number
        self.single = single
        self.run = run
    }
}

/// How a widget is drawn. The extension passes WidgetKit's environment (`widgetFamily`,
/// `widgetRenderingMode`); the app's widget gallery passes the same values to show every variant.
public struct WidgetStyle: Sendable, Hashable {
    public var family: WidgetFamily
    /// Tinted Home Screen or the Lock Screen: one colour, so no filled colours; accented parts
    /// marked with `widgetAccentable`.
    public var isAccented: Bool

    public init(family: WidgetFamily, isAccented: Bool = false) {
        self.family = family
        self.isAccented = isAccented
    }

    public init(family: WidgetFamily, renderingMode: WidgetRenderingMode) {
        self.init(family: family, isAccented: renderingMode != .fullColor)
    }

    /// A widget is a fixed size: its text grows with Dynamic Type up to here, then stops (the
    /// accessibility sizes would push names and controls out). VoiceOver reads it all regardless.
    public static let largestTypeSize = DynamicTypeSize.xxLarge
}

// MARK: - One topic

/// The per-topic quick-log widget: name, due pill, the "Last …" line, "queued" while this device's
/// logs wait to sync, "Update quickR" while this build is too old for the server
/// (client-versions.md §4.1), and the quick-log (chips, or "✓ last" for a number). Chips and ✓ open
/// the record screen for now; INTENTS makes them log in place.
public struct TopicWidgetView: View {
    let topic: WidgetTopic?
    let date: Date
    let style: WidgetStyle
    let actions: WidgetActions?
    private let text = TopicText()

    public init(topic: WidgetTopic?, date: Date, style: WidgetStyle, actions: WidgetActions? = nil) {
        self.topic = topic
        self.date = date
        self.style = style
        self.actions = actions
    }

    public var body: some View {
        Group {
            if let topic, topic.runTile.isTimed {
                switch style.family {
                case .accessoryInline: timedInline(topic)
                case .accessoryCircular: timedCircular(topic)
                case .accessoryRectangular: timedRectangular(topic)
                default: timedHome(topic)
                }
            } else if let topic {
                switch style.family {
                case .accessoryInline: inline(topic)
                case .accessoryCircular: circular(topic)
                case .accessoryRectangular: rectangular(topic)
                default: home(topic)
                }
            } else {
                Text(style.family == .accessoryInline ? "quickR: choose a topic" : "Choose a topic")
                    .font(.qr(.callout))
                    .foregroundStyle(.qr.muted)
            }
        }
        .dynamicTypeSize(...WidgetStyle.largestTypeSize)
    }

    private func home(_ topic: WidgetTopic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name, due, queued and the last line read as one element; the controls stay apart.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(topic.topic.name)
                        .font(.qr(.section))
                        .foregroundStyle(.qr.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    if topic.queued > 0 { QueuedMark(count: topic.queued, compact: style.family == .systemSmall) }
                }
                DueBadge(topic.dueView(at: date))
                    .lineLimit(1)
                    .widgetAccentable()
                lastLine(topic)
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.muted)
                    .lineLimit(topic.updateRequired ? 1 : 2)
                if topic.updateRequired { UpdateMark() }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            quick(topic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(topic.recordURL)
    }

    @ViewBuilder private func quick(_ topic: WidgetTopic) -> some View {
        switch topic.quick {
        case .chips(_, let options):
            let shown = Array(options.prefix(style.family == .systemSmall ? 4 : 6))
            let columns = style.family == .systemSmall ? 2 : 3
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: shown.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(shown[start..<min(start + columns, shown.count)], id: \.value) { option in
                            control(actions?.option(option), topic) {
                                WidgetChip(
                                    label: option.label, isLast: topic.lastAnswer == .string(option.value),
                                    isAccented: style.isAccented)
                            }
                            .accessibilityLabel("Log \(option.label)")
                            // The dot marks the last answer; say it too.
                            .accessibilityValue(topic.lastAnswer == .string(option.value) ? "Last answer" : "")
                        }
                    }
                }
            }
        case .number(let question):
            // Shows exactly what it logs (the last value, or the start once the rules changed).
            let last = topic.checkAnswer.flatMap { text.answer($0, for: question) }
            control(topic.checkAnswer.flatMap { actions?.number($0) }, topic) {
                WidgetChip(label: "✓ " + (last ?? "Log"), isLast: false, isAccented: style.isAccented, isPrimary: true)
            }
            .accessibilityLabel(last.map { "Log \($0)" } ?? "Log \(topic.topic.name)")
        case .single:
            // No questions: one tap logs it.
            control(actions?.single(), topic) {
                WidgetChip(label: "Log it", isLast: false, isAccented: style.isAccented, isPrimary: true)
            }
            .accessibilityLabel("Log \(topic.topic.name)")
        case nil:
            Link(destination: topic.recordURL) {
                WidgetChip(label: "Log", isLast: false, isAccented: style.isAccented, isPrimary: true)
            }
            .accessibilityLabel("Log \(topic.topic.name)")
        }
    }

    /// A control: runs `intent` in place (no app), or opens the record screen without one.
    @ViewBuilder private func control(
        _ intent: (any AppIntent)?, _ topic: WidgetTopic, @ViewBuilder label: () -> some View
    ) -> some View {
        if let intent {
            // The intent's type is only known at run time: the button is type-erased.
            AnyView(intentButton(intent, label: label()))
        } else {
            Link(destination: topic.recordURL, label: label)
        }
    }

    private func intentButton(_ intent: some AppIntent, label: some View) -> some View {
        Button(intent: intent) { label }.buttonStyle(.plain)
    }

    private func lastLine(_ topic: WidgetTopic) -> Text {
        guard topic.topic.entryCount > 0 || topic.queued > 0 else { return Text("No entries yet") }
        let when = text.relative(topic.topic.lastCapturedAt, now: date)
        if let question = topic.quick?.question, let last = topic.lastAnswer,
            let answer = text.answer(last, for: question)
        {
            return Text("Last \(Text(answer).fontWeight(.semibold).foregroundStyle(.qr.inkSoft)) · \(when)")
        }
        return Text("\(text.count(topic.topic.entryCount, "entry", "entries")) · \(when)")
    }

    private func rectangular(_ topic: WidgetTopic) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(topic.topic.name).font(.headline).widgetAccentable().lineLimit(1)
                if topic.queued > 0 {
                    Image(systemName: "clock.arrow.circlepath").font(.caption)
                        .accessibilityLabel("\(topic.queued) waiting to sync")
                }
            }
            if let due = dueLabel(topic) { Text(due).font(.caption).lineLimit(1) }
            // Three lines fit: the update notice takes the last one's place.
            if topic.updateRequired {
                Text(UpdateMark.text).font(.caption).lineLimit(1)
            } else {
                lastLine(topic).font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(topic.recordURL)
    }

    private func circular(_ topic: WidgetTopic) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(
                    systemName: topic.countsAsDue(at: date) ? "bell.fill" : "checkmark"
                )
                .font(.system(size: 14, weight: .semibold))
                .widgetAccentable()
                Text(String(topic.topic.name.prefix(5))).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        }
        .widgetURL(topic.recordURL)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(topic.topic.name), \(dueLabel(topic) ?? "not due")")
    }

    private func inline(_ topic: WidgetTopic) -> some View {
        Text([topic.topic.name, dueLabel(topic)].compactMap { $0 }.joined(separator: " · "))
            .widgetURL(topic.recordURL)
    }

    private func dueLabel(_ topic: WidgetTopic) -> String? {
        let view = topic.dueView(at: date)
        return view.kind == .none ? nil : view.label()
    }

    // MARK: Timed (timers.md §11.3)

    /// A timed topic: never a one-tap log. Idle, its due state and Start; running, the segment's
    /// label, its ticking timer and the total, and Next (or Lap) and Stop, the small size one
    /// Auto button; finishing, "Add details", which opens its answers form. A tap elsewhere opens
    /// the run screen.
    private func timedHome(_ topic: WidgetTopic) -> some View {
        let display = topic.runDisplay
        let state = topic.runTile
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.topic.name)
                    .font(.qr(.section))
                    .foregroundStyle(.qr.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                switch state {
                case .open(let paused):
                    if let display {
                        Text(paused ? "Paused · \(display.label)" : display.label)
                            .font(.qr(.footnote))
                            .foregroundStyle(.qr.muted)
                            .lineLimit(1)
                        RunWidgetTimer(timer: display.segmentTimer)
                            .font(.qr(.title))
                            .foregroundStyle(.qr.ink)
                            .widgetAccentable()
                        if style.family != .systemSmall {
                            RunWidgetTimer(timer: display.totalTimer)
                                .font(.qr(.footnote))
                                .foregroundStyle(.qr.muted)
                        }
                    }
                case .finishing:
                    Text("Add details")
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.warn)
                    if topic.dueView(at: date).kind != .none {
                        DueBadge(topic.dueView(at: date)).lineLimit(1).widgetAccentable()
                    }
                case .idle, .untimed:
                    DueBadge(topic.dueView(at: date)).lineLimit(1).widgetAccentable()
                    lastLine(topic)
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.muted)
                        .lineLimit(topic.updateRequired ? 1 : 2)
                }
                if topic.updateRequired { UpdateMark() }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            runControls(topic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(topic.runURL)
    }

    @ViewBuilder private func runControls(_ topic: WidgetTopic) -> some View {
        if topic.runTile == .finishing {
            Link(destination: topic.runURL) {
                WidgetChip(label: "Add details", isLast: false, isAccented: style.isAccented, isPrimary: true)
            }
            .accessibilityLabel("Add details to \(topic.topic.name)")
        } else {
            let compact = style.family == .systemSmall
            HStack(spacing: 6) {
                ForEach(topic.runButtons(compact: compact), id: \.self) { button in
                    runControl(actions?.run(button), topic) {
                        WidgetChip(
                            label: compact && button == .next
                                ? (topic.run?.nextLabel.map { "Next: \($0)" } ?? "Next")
                                : button.title,
                            isLast: false, isAccented: style.isAccented, isPrimary: button != .lap)
                    }
                    .accessibilityLabel(topic.runButtonLabel(button))
                }
            }
        }
    }

    /// A run button: runs `intent` in place, or opens the run screen without one (the gallery).
    @ViewBuilder private func runControl(
        _ intent: (any AppIntent)?, _ topic: WidgetTopic, @ViewBuilder label: () -> some View
    ) -> some View {
        if let intent {
            AnyView(intentButton(intent, label: label()))
        } else {
            Link(destination: topic.runURL, label: label)
        }
    }

    /// The Lock Screen's: the name, then the open segment and its timer, "Add details", or the due
    /// state. It opens the run screen.
    private func timedRectangular(_ topic: WidgetTopic) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(topic.topic.name).font(.headline).widgetAccentable().lineLimit(1)
            if case .open = topic.runTile, let display = topic.runDisplay {
                Text(display.label).font(.caption).lineLimit(1)
                RunWidgetTimer(timer: display.segmentTimer).font(.caption)
            } else {
                Text(topic.runTile == .finishing ? "Add details" : dueLabel(topic) ?? "Start")
                    .font(.caption).lineLimit(1)
                // The third line, which a running segment's timer takes.
                if topic.updateRequired { Text(UpdateMark.text).font(.caption).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(topic.runURL)
    }

    private func timedCircular(_ topic: WidgetTopic) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: topic.hasOpenRun ? "timer" : topic.countsAsDue(at: date) ? "bell.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .widgetAccentable()
                Text(String(topic.topic.name.prefix(5))).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        }
        .widgetURL(topic.runURL)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(topic.topic.name), \(timedStatus(topic))")
    }

    private func timedInline(_ topic: WidgetTopic) -> some View {
        Text("\(topic.topic.name) · \(timedStatus(topic))").widgetURL(topic.runURL)
    }

    /// "Running", "Paused", "Add details", or the due state ("not due").
    private func timedStatus(_ topic: WidgetTopic) -> String {
        switch topic.runTile {
        case .open(let paused): paused ? "Paused" : "Running"
        case .finishing: "Add details"
        case .idle, .untimed: dueLabel(topic) ?? "not due"
        }
    }
}

// MARK: - Due list

/// The due-list widget: what's due now, then what's coming, as on the home screen. Each row opens
/// that topic's record screen.
public struct DueListWidgetView: View {
    let topics: [WidgetTopic]
    let date: Date
    let style: WidgetStyle

    public init(topics: [WidgetTopic], date: Date, style: WidgetStyle) {
        self.topics = topics
        self.date = date
        self.style = style
    }

    /// The due count's own rule (`TopicListing.countsAsDue`): a topic with an open run isn't due.
    private var dueNow: [WidgetTopic] { topics.filter { $0.countsAsDue(at: date) } }

    /// Every topic comes from one store: it is too old for its server (client-versions.md §4.1).
    private var updateRequired: Bool { topics.contains { $0.updateRequired } }

    /// Due and scheduled topics, in the list's order; plain ones only fill a large widget.
    private var rows: [WidgetTopic] {
        let scheduled = topics.filter { $0.topic.schedule != nil }
        let limit =
            switch style.family {
            case .systemLarge, .systemExtraLarge: 7
            case .accessoryRectangular: 2
            default: 3
            }
        return Array(scheduled.prefix(limit))
    }

    public var body: some View {
        content.dynamicTypeSize(...WidgetStyle.largestTypeSize)
    }

    @ViewBuilder private var content: some View {
        switch style.family {
        case .accessoryInline:
            Text(inlineText)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("\(dueNow.count)").font(.system(size: 20, weight: .bold)).widgetAccentable()
                    Text("due").font(.system(size: 10, weight: .semibold))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(dueNow.count) due")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(dueNow.isEmpty ? "Nothing due" : "\(dueNow.count) due")
                    .font(.headline)
                    .widgetAccentable()
                ForEach(rows) { topic in
                    Text(
                        "\(topic.topic.name) · \(topic.hasOpenRun ? "Running" : topic.dueView(at: date).label())"
                    )
                    .font(.caption)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            home
        }
    }

    private var inlineText: String {
        guard let first = dueNow.first else { return "Nothing due" }
        return dueNow.count == 1 ? "\(first.topic.name) is due" : "\(dueNow.count) due · \(first.topic.name)"
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.qr.accent).frame(width: 7, height: 7).widgetAccentable()
                Text("DUE NOW")
                    .font(.qr(.caption))
                    .tracking(1)
                    .foregroundStyle(.qr.accentStrong)
                    .widgetAccentable()
                Text("\(dueNow.count)").font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
            }
            // One heading, "2 due now", instead of "DUE NOW" and a bare number.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(dueNow.count) due now")
            .accessibilityAddTraits(.isHeader)
            if updateRequired { UpdateMark() }
            if rows.isEmpty {
                Text("Nothing due — you’re all caught up.")
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.muted)
            }
            ForEach(rows) { topic in
                // A timed topic opens its run screen, like its tile (timers.md §11.3).
                Link(destination: topic.runTile.isTimed ? topic.runURL : topic.recordURL) {
                    HStack(spacing: 8) {
                        Text(topic.topic.name)
                            .font(.qr(.callout))
                            .foregroundStyle(.qr.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if topic.queued > 0 { QueuedMark(count: topic.queued, compact: true) }
                        DueBadge(topic.dueView(at: date))
                            .lineLimit(1)
                            .fixedSize()
                            .widgetAccentable()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Parts

/// A chip in a widget (an option, or "✓ last"): the last answer gets a dot, like the tile's.
struct WidgetChip: View {
    let label: String
    let isLast: Bool
    let isAccented: Bool
    var isPrimary = false

    var body: some View {
        HStack(spacing: 4) {
            if isLast { Circle().fill(Color.qr.accent).frame(width: 5, height: 5).widgetAccentable() }
            Text(label).font(.qr(.label)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(isPrimary && !isAccented ? Color.qr.onAccent : Color.qr.ink)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if isAccented {
                shape.strokeBorder(.secondary, lineWidth: 1)
            } else if isPrimary {
                shape.fill(Color.qr.accent)
            } else {
                shape.fill(Color.qr.surface).overlay(shape.strokeBorder(Color.qr.lineStrong, lineWidth: 1))
            }
        }
        .widgetAccentable(isPrimary)
    }
}

/// A run's ticking timer, frozen at its pause (the system draws it: no timeline entries).
struct RunWidgetTimer: View {
    let timer: RunActivityDisplay.Timer?

    var body: some View {
        if let timer {
            Text(
                timerInterval: Date(timeIntervalSince1970: timer.start)...Date.distantFuture,
                pauseTime: timer.pausedAt.map { Date(timeIntervalSince1970: $0) }, countsDown: false
            )
            .monospacedDigit()
        }
    }
}

/// "Update quickR": this build is too old for the server (client-versions.md §4.1). Taps are
/// still kept on the iPhone; they sync once quickR is updated.
struct UpdateMark: View {
    static let text = "Update quickR"

    var body: some View {
        Label(Self.text, systemImage: "arrow.down.app")
            .font(.qr(.caption))
            .foregroundStyle(.qr.warn)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .accessibilityLabel("Update quickR to sync")
    }
}

/// "Queued": logs from this device that haven't synced yet.
struct QueuedMark: View {
    let count: Int
    let compact: Bool

    var body: some View {
        Label(compact ? "\(count)" : "\(count) queued", systemImage: "clock.arrow.circlepath")
            .font(.qr(.caption))
            .foregroundStyle(.qr.info)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("\(count) waiting to sync")
    }
}
#endif
