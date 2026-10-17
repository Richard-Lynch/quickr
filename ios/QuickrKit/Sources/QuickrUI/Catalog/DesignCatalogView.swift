#if os(iOS)
import SwiftUI

/// Every token and component on four pages, with local sample values. A debug aid and the
/// source of the design-system screenshots; flip the simulator's appearance for dark.
public struct DesignCatalogView: View {
    public enum Page: String, CaseIterable, Identifiable, Sendable {
        case colors
        case type
        case controls
        case tiles

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .colors: "Colours"
            case .type: "Type & icons"
            case .controls: "Controls"
            case .tiles: "Tiles"
            }
        }
    }

    @State private var page: Page
    @State private var toasts = ToastCenter()

    public init(page: Page = .colors) {
        _page = State(initialValue: page)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Page", selection: $page) {
                        ForEach(Page.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch page {
                    case .colors: ColorsPage()
                    case .type: TypePage()
                    case .controls: ControlsPage()
                    case .tiles: TilesPage()
                    }
                }
                .padding(16)
            }
            .qrPaperBackground()
            .navigationTitle("Design system")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toastHost(toasts)
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.qr(.section))
            .tracking(-0.3)
            .foregroundStyle(.qr.ink)
            .padding(.top, 4)
    }
}

// MARK: - Colours

private struct ColorsPage: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Tokens · \(scheme == .dark ? "dark" : "light")")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(QuickrPalette.tokenNames, id: \.self) { name in
                    Swatch(name: name)
                }
            }
            SectionHeader("Tones")
            FlowRow {
                ForEach(Array(QuickrTone.allCases.enumerated()), id: \.offset) { _, tone in
                    QuickrBadge(String(describing: tone), tone: tone)
                }
            }
            SectionHeader("Surfaces")
            HStack(spacing: 12) {
                Card { Text("Card · 18 pt").font(.qr(.callout)) }
                Text("Float")
                    .font(.qr(.callout))
                    .foregroundStyle(.qr.paper)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.qr.ink, in: RoundedRectangle(cornerRadius: 16))
                    .qrShadow(.float)
            }
        }
    }
}

private struct Swatch: View {
    let name: String
    @Environment(\.self) private var environment

    var body: some View {
        let color = Color.qr.token(name)
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.qr.line))
            Text(name).font(.qr(.caption)).foregroundStyle(.qr.ink)
            Text(hex(color)).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
        }
    }

    private func hex(_ color: Color) -> String {
        let c = color.resolve(in: environment)
        let v = [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2])
    }
}

// MARK: - Type and icons

private struct TypePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Type ramp")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(QuickrTextStyle.allCases.enumerated()), id: \.offset) { _, style in
                    HStack(alignment: .firstTextBaseline) {
                        Text(sample(style)).font(.qr(style)).foregroundStyle(.qr.ink)
                        Spacer()
                        Text(String(describing: style)).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
                    }
                }
            }
            .padding(16)
            .qrCard()
            SectionHeader("Icons")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 12) {
                ForEach(QIcon.allCases, id: \.self) { icon in
                    VStack(spacing: 4) {
                        icon.view(size: 24).foregroundStyle(.qr.ink)
                        Text(icon.rawValue)
                            .font(.qr(.monoCaption))
                            .foregroundStyle(.qr.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
            }
            .padding(12)
            .qrCard()
            HStack(spacing: 12) {
                QuickrMark(size: 32)
                Text("quick\(Text("R").foregroundStyle(.qr.accent))")
                    .font(.qr(.displayBold, size: 22, relativeTo: .title2))
                    .foregroundStyle(.qr.ink)
                Spacer()
            }
        }
    }

    private func sample(_ style: QuickrTextStyle) -> String {
        switch style {
        case .largeTitle: "Due now"
        case .title: "Mood check-in"
        case .section: "Topics"
        case .label: "Workout type"
        case .body: "Tap an answer to log it."
        case .callout: "Moderate"
        case .subheadline: "Logged Mild"
        case .footnote: "Last None · 6 hours ago"
        case .caption: "Overdue · since 7:59 PM"
        case .mono: "72.5"
        case .monoCaption: "2 selected · pick 1–2"
        }
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    @State private var single: String? = "mild"
    @State private var multi: [String] = ["run", "yoga"]
    @State private var minutes = "50"
    @State private var distance = ""
    @State private var weight = "72.5"
    @State private var loading = false

    private let severity = [
        ChipOption("none", label: "None"), ChipOption("mild", label: "Mild"),
        ChipOption("moderate", label: "Moderate"), ChipOption("severe", label: "Severe"),
    ]
    private let workouts = [
        ChipOption("run", label: "Run"), ChipOption("strength", label: "Strength"), ChipOption("yoga", label: "Yoga"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Chips")
            VStack(alignment: .leading, spacing: 16) {
                label("Severity", note: "single · optional")
                ChipGrid("Severity", options: severity, selection: $single, required: false)
                label("Workout type", note: "\(multi.count) selected · pick 1–2")
                ChipGrid("Workout type", options: workouts, selection: $multi, min: 1, max: 2)
            }
            .padding(16)
            .qrCard()
            SectionHeader("Stepper")
            VStack(alignment: .leading, spacing: 16) {
                label("Duration", note: "int · 0–600 · min")
                NumberStepper(
                    text: $minutes, rule: NumberStepRule(integer: true, min: 0, max: 600), unit: "min",
                    label: "Duration")
                label("Distance", note: "1 decimal · ≥ 0 · empty")
                NumberStepper(
                    text: $distance, rule: NumberStepRule(integer: false, min: 0, decimals: 1), unit: "km",
                    label: "Distance")
                label("Weight", note: "invalid")
                NumberStepper(
                    text: $weight, rule: NumberStepRule(integer: false, min: 30, max: 70, decimals: 1), unit: "kg",
                    label: "Weight", isInvalid: true)
            }
            .padding(16)
            .qrCard()
            SectionHeader("Buttons")
            VStack(spacing: 10) {
                PrimaryButton("Save", icon: .check, isLoading: loading) { loading.toggle() }
                HStack(spacing: 8) {
                    Button("Medium · 44") {}.buttonStyle(.qr(.primary))
                    Button("Small · 36") {}.buttonStyle(.qr(.primary, size: .small))
                }
                HStack(spacing: 8) {
                    Button("Secondary") {}.buttonStyle(.qr(.secondary))
                    Button("Ghost") {}.buttonStyle(.qr(.ghost))
                    Button("Disabled") {}.buttonStyle(.qr(.secondary)).disabled(true)
                }
                HStack(spacing: 8) {
                    Button("Delete") {}.buttonStyle(.qr(.danger))
                    Button("Discard") {}.buttonStyle(.qr(.quietDanger))
                    QuickrIconButton(.plus, label: "New topic", bordered: true) {}
                    QuickrIconButton(.settings, label: "Settings") {}
                }
            }
        }
    }

    private func label(_ title: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.qr(.label)).foregroundStyle(.qr.ink)
            Spacer()
            Text(note).font(.qr(.monoCaption)).foregroundStyle(.qr.muted)
        }
    }
}

// MARK: - Tiles and feedback

private struct TilesPage: View {
    @Environment(ToastCenter.self) private var toasts
    @State private var glasses = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(Color.qr.accent).frame(width: 7, height: 7)
                Text("DUE NOW").font(.qr(.caption)).tracking(1).foregroundStyle(.qr.accentStrong)
                Text("2").font(.qr(.monoCaption)).foregroundStyle(.qr.accentStrong)
                Spacer()
                SyncPill(online: false, pending: 0, failed: 0) {}
                SyncPill(online: true, pending: 3, failed: 0) {}
                SyncPill(online: true, pending: 0, failed: 2) {}
            }
            TileView(title: "Water", isDue: true, onOpen: {}, onLog: {}) {
                VStack(alignment: .leading, spacing: 4) {
                    QuickrBadge("Overdue · since 7:59 PM", icon: .bell, tone: .danger)
                    Text("Last **0 glasses** · 4 hours ago")
                }
            } quick: {
                QuickNumberRow(label: "Glasses", text: $glasses, rule: NumberStepRule(integer: true, min: 0)) {
                    toasts.show(Toast("Logged \(glasses) glasses", message: "Water", action: .init("Undo") {}))
                }
            }
            TileView(title: "Headache", isDue: true, onOpen: {}, onLog: {}) {
                VStack(alignment: .leading, spacing: 4) {
                    QuickrBadge("Due now · since 9:00 PM", icon: .bell, tone: .accent)
                    Text("Last **None** · 6 hours ago")
                }
            } quick: {
                QuickChipGrid(
                    options: [
                        ChipOption("none", label: "None"), ChipOption("mild", label: "Mild"),
                        ChipOption("moderate", label: "Moderate"), ChipOption("severe", label: "Severe"),
                    ], last: "none", label: "Log Headache"
                ) { option in
                    toasts.show(Toast("Logged \(option.label)", message: "Headache", action: .init("Undo") {}))
                    return true
                }
            }
            TileView(title: "Symptoms", isDue: false, onOpen: {}, onLog: {}) {
                VStack(alignment: .leading, spacing: 4) {
                    QuickrBadge("Tomorrow 8:00 AM", icon: .clock)
                    Text("1 entry · 27 minutes ago")
                }
            }
            SectionHeader("Toasts")
            ToastView(Toast("Logged Mild", message: "Headache", action: .init("Undo") {}), onAction: {}, onDismiss: {})
            ToastView(
                Toast("Saved on this device", message: "Syncs when you’re back online", tone: .info), onAction: {},
                onDismiss: {})
            ToastView(Toast("Couldn’t log: topic archived", tone: .danger), onAction: {}, onDismiss: {})
            HStack {
                Button("Show undo toast") {
                    toasts.show(Toast("Logged Moderate", message: "Headache", action: .init("Undo") {}))
                }
                Button("Plain") { toasts.show(Toast("Copied", tone: .info)) }
            }
            .buttonStyle(.qr(.secondary, size: .small))
        }
    }
}

/// Wraps children onto new lines (for badges).
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (point, subview) in zip(arrange(bounds.width, subviews).points, subviews) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}

#Preview("Catalogue") { DesignCatalogView() }
#Preview("Catalogue · tiles") { DesignCatalogView(page: .tiles) }
#endif
