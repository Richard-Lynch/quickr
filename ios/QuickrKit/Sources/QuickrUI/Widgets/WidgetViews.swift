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

    public init(
        option: @escaping (EnumOption) -> (any AppIntent)?, number: @escaping (AnswerValue) -> (any AppIntent)?
    ) {
        self.option = option
        self.number = number
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
/// logs wait to sync, and the quick-log (chips, or "✓ last" for a number). Chips and ✓ open the
/// record screen for now; INTENTS makes them log in place.
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
            if let topic {
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
            HStack(alignment: .firstTextBaseline) {
                Text(topic.topic.name)
                    .font(.qr(.section))
                    .foregroundStyle(.qr.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if topic.queued > 0 { QueuedMark(count: topic.queued, compact: style.family == .systemSmall) }
            }
            DueBadge(DueView(due: topic.due(at: date), now: date))
                .lineLimit(1)
                .widgetAccentable()
            lastLine(topic)
                .font(.qr(.footnote))
                .foregroundStyle(.qr.muted)
                .lineLimit(2)
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
        case nil:
            Link(destination: topic.recordURL) {
                WidgetChip(label: "Log", isLast: false, isAccented: style.isAccented, isPrimary: true)
            }
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
        if let quick = topic.quick, let last = topic.lastAnswer, let answer = text.answer(last, for: quick.question) {
            return Text("Last \(Text(answer).fontWeight(.semibold).foregroundStyle(.qr.inkSoft)) · \(when)")
        }
        return Text("\(text.count(topic.topic.entryCount, "entry", "entries")) · \(when)")
    }

    private func rectangular(_ topic: WidgetTopic) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(topic.topic.name).font(.headline).widgetAccentable().lineLimit(1)
                if topic.queued > 0 { Image(systemName: "clock.arrow.circlepath").font(.caption) }
            }
            if let due = dueLabel(topic) { Text(due).font(.caption).lineLimit(1) }
            lastLine(topic).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(topic.recordURL)
    }

    private func circular(_ topic: WidgetTopic) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: DueView.isDueNow(topic.due(at: date), now: date) ? "bell.fill" : "checkmark")
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
        let view = DueView(due: topic.due(at: date), now: date)
        return view.kind == .none ? nil : view.label()
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

    private var dueNow: [WidgetTopic] { topics.filter { DueView.isDueNow($0.due(at: date), now: date) } }

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
                    Text("\(topic.topic.name) · \(DueView(due: topic.due(at: date), now: date).label())")
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
            if rows.isEmpty {
                Text("Nothing due — you’re all caught up.")
                    .font(.qr(.footnote))
                    .foregroundStyle(.qr.muted)
            }
            ForEach(rows) { topic in
                Link(destination: topic.recordURL) {
                    HStack(spacing: 8) {
                        Text(topic.topic.name)
                            .font(.qr(.callout))
                            .foregroundStyle(.qr.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if topic.queued > 0 { QueuedMark(count: topic.queued, compact: true) }
                        DueBadge(DueView(due: topic.due(at: date), now: date))
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
