#if os(iOS)
import SwiftUI

/// The home screen's topic tile (the PWA's `TopicTile`): title, a meta row, an optional
/// quick-log area, and a full-height Log block on the thumb side. A due tile gets an accent
/// bar, an accent border and a filled Log block.
///
/// Content comes through slots so the tile knows nothing about topics: pass badges and the
/// "Last …" line as `meta`, and ``QuickChipGrid`` or a ``NumberStepper`` row as `quick`.
public struct TileView<Meta: View, Quick: View>: View {
    let title: String
    let isDue: Bool
    let onOpen: () -> Void
    let action: TileAction?
    let meta: Meta
    let quick: Quick
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var plusSize: CGFloat = 24

    /// - Parameters:
    ///   - onOpen: tapping anywhere outside the controls opens the topic.
    ///   - onLog: the Log block's action; nil hides it (archived topics).
    public init(
        title: String, isDue: Bool, onOpen: @escaping () -> Void, onLog: (() -> Void)?,
        @ViewBuilder meta: () -> Meta, @ViewBuilder quick: () -> Quick
    ) {
        self.init(
            title: title, isDue: isDue, onOpen: onOpen, action: onLog.map { TileAction.log(title: title, $0) },
            meta: meta, quick: quick)
    }

    /// A tile whose block does `action` instead of Log (a timed topic's Start, Next, Stop or Add
    /// details); nil hides it.
    public init(
        title: String, isDue: Bool, onOpen: @escaping () -> Void, action: TileAction?,
        @ViewBuilder meta: () -> Meta, @ViewBuilder quick: () -> Quick
    ) {
        self.title = title
        self.isDue = isDue
        self.onOpen = onOpen
        self.action = action
        self.meta = meta()
        self.quick = quick()
    }

    public var body: some View {
        // At accessibility sizes the Log block goes under the body, full width: beside it, its
        // fixed column left the quick-log too narrow for its digits (audit H4).
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.qr(.title))
                        .tracking(-0.4)
                        .foregroundStyle(.qr.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    meta
                        .font(.qr(.footnote))
                        .foregroundStyle(.qr.muted)
                }
                // Text passes taps through to the open button behind it.
                .allowsHitTesting(false)
                // For VoiceOver the title, badges and "Last …" line are the open button: one
                // element that reads them all (audit H2). The button behind is for touch only.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the topic")
                .accessibilityAction(.default, onOpen)
                quick
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Button(action: onOpen) { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
            }
            if let action { logBlock(action, stacked: stacked) }
        }
        .overlay(alignment: .leading) {
            if isDue { Color.qr.accent.frame(width: 4).accessibilityHidden(true) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .qrCard(border: isDue ? .qr.accent.opacity(0.45) : .qr.line)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func logBlock(_ action: TileAction, stacked: Bool) -> some View {
        let loud = action.loud ?? isDue
        return Button(action: action.perform) {
            let layout = stacked ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))
            layout {
                action.icon.view(size: plusSize, weight: .bold)
                Text(action.title).font(.qr(.callout)).multilineTextAlignment(.center)
            }
            .foregroundStyle(loud ? Color.qr.onAccent : .qr.accentStrong)
            .frame(width: stacked ? nil : QuickrMetrics.logBlockWidth)
            .frame(maxWidth: stacked ? .infinity : nil, maxHeight: .infinity)
            .frame(minHeight: stacked ? QuickrMetrics.tapTarget + 12 : nil)
            .background(loud ? Color.qr.accent : .qr.accentSoft)
            .overlay(alignment: stacked ? .top : .leading) {
                let line = loud ? Color.qr.accentStrong.opacity(0.3) : .qr.line
                if stacked { line.frame(height: 1) } else { line.frame(width: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickrPressStyle())
        .disabled(action.disabled)
        .accessibilityLabel(action.label)
        .accessibilityIdentifier(action.identifier ?? "")
    }
}

/// The tile's full-height block: Log, or a timed topic's run control.
public struct TileAction {
    public var icon: QIcon
    public var title: String
    /// What VoiceOver reads ("Log Water", "Next: Teeth · Morning").
    public var label: String
    public var identifier: String?
    /// Filled (accent) or soft; nil follows the tile's due state, as Log does.
    public var loud: Bool?
    public var disabled: Bool
    public var perform: () -> Void

    public init(
        icon: QIcon, title: String, label: String, identifier: String? = nil, loud: Bool? = nil,
        disabled: Bool = false, perform: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.label = label
        self.identifier = identifier
        self.loud = loud
        self.disabled = disabled
        self.perform = perform
    }

    static func log(title: String, _ perform: @escaping () -> Void) -> TileAction {
        TileAction(icon: .plus, title: "Log", label: "Log \(title)", perform: perform)
    }
}

extension TileView where Quick == EmptyView {
    /// A tile without quick-log.
    public init(
        title: String, isDue: Bool, onOpen: @escaping () -> Void, onLog: (() -> Void)?,
        @ViewBuilder meta: () -> Meta
    ) {
        self.init(title: title, isDue: isDue, onOpen: onOpen, onLog: onLog, meta: meta, quick: { EmptyView() })
    }
}

/// The tile's number quick-log: a small label, a compact stepper and the ink ✓ button.
public struct QuickNumberRow: View {
    let label: String
    @Binding var text: String
    let rule: NumberStepRule
    let unit: String?
    let isBusy: Bool
    let error: String?
    let onLog: () -> Void
    @ScaledMetric(relativeTo: .title3) private var height = QuickrMetrics.tapTarget
    @ScaledMetric(relativeTo: .title3) private var checkSize: CGFloat = 20
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Counts Log taps, so a repeated error is read again.
    @State private var attempts = 0

    public init(
        label: String, text: Binding<String>, rule: NumberStepRule, unit: String? = nil, isBusy: Bool = false,
        error: String? = nil, onLog: @escaping () -> Void
    ) {
        self.label = label
        self._text = text
        self.rule = rule
        self.unit = unit
        self.isBusy = isBusy
        self.error = error
        self.onLog = onLog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.qr(.sansMedium, size: 12, relativeTo: .caption))
                .foregroundStyle(.qr.muted)
                .accessibilityHidden(true)
            // At accessibility sizes the ✓ goes under the stepper, which keeps the width for its digits.
            let stacked = typeSize.isAccessibilitySize
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
            layout {
                NumberStepper(text: $text, rule: rule, label: label, size: .compact, isInvalid: error != nil)
                    .disabled(isBusy)
                    .accessibilityIdentifier("quick.number")
                    .accessibilityHint(error.map { "Error: \($0)" } ?? "")
                Button {
                    attempts += 1
                    onLog()
                } label: {
                    QIcon.check.view(size: checkSize, weight: .heavy)
                        .foregroundStyle(.qr.paper)
                        .frame(width: stacked ? nil : max(48, checkSize + 16), height: height)
                        .frame(maxWidth: stacked ? .infinity : nil)
                        .background(Color.qr.ink, in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuickrPressStyle(scale: 0.95))
                .disabled(isBusy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(isBusy || text.isEmpty ? 0.4 : 1)
                // "Log 3 glasses", like the PWA's.
                .accessibilityLabel("Log \(text.isEmpty ? label : text)\(unit.map { " \($0)" } ?? "")")
                .accessibilityIdentifier("quick.check")
            }
            if let error {
                Text(error)
                    .font(.qr(.sansMedium, size: 12, relativeTo: .caption))
                    .foregroundStyle(.qr.danger)
                    .qrAnnouncesError(error, trigger: attempts)
            }
        }
    }
}

private struct TilePreview: View {
    @State var glasses = "0"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TileView(title: "Water", isDue: true, onOpen: {}, onLog: {}) {
                    VStack(alignment: .leading, spacing: 4) {
                        QuickrBadge("Overdue · since 7:59 PM", icon: .bell, tone: .danger)
                        Text("Last **0 glasses** · 4 hours ago")
                    }
                } quick: {
                    QuickNumberRow(label: "Glasses", text: $glasses, rule: NumberStepRule(integer: true, min: 0)) {}
                }
                TileView(title: "Headache", isDue: true, onOpen: {}, onLog: {}) {
                    QuickrBadge("Due now · since 9:00 PM", icon: .bell, tone: .accent)
                } quick: {
                    DemoQuickChipGrid(
                        options: [
                            ChipOption("none", label: "None"), ChipOption("mild", label: "Mild"),
                            ChipOption("moderate", label: "Moderate"), ChipOption("severe", label: "Severe"),
                        ], last: "none", label: "Log Headache"
                    ) { _ in true }
                }
                TileView(title: "Symptoms", isDue: false, onOpen: {}, onLog: {}) {
                    VStack(alignment: .leading, spacing: 4) {
                        QuickrBadge("Tomorrow 8:00 AM", icon: .clock)
                        Text("1 entry · 27 minutes ago")
                    }
                }
            }
            .padding(16)
        }
        .qrPaperBackground()
    }
}

#Preview("Tiles") { TilePreview() }
#endif
