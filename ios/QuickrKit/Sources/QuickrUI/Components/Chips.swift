#if os(iOS)
import SwiftUI

/// One choice: `value` is what gets stored, `label` what is shown.
public struct ChipOption: Identifiable, Hashable, Sendable {
    public var value: String
    public var label: String
    public var id: String { value }

    public init(_ value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// How a chip looks. `.form` is the record screen's 52 pt chip (accent when selected);
/// `.quick` is the tile's 44 pt quick-log chip (green ✓ flash after logging).
public enum ChipStyle: Sendable {
    case form
    case quick
}

/// A tappable answer chip. Selection semantics (radio, checkbox, or a plain button) are
/// announced through VoiceOver traits.
public struct Chip: View {
    public enum Role: Sendable {
        /// Single select: one of a group.
        case radio
        /// Multi select: toggles on and off.
        case checkbox
        /// Logs straight away (tile quick-log).
        case button
    }

    let label: String
    let role: Role
    let style: ChipStyle
    let isSelected: Bool
    let isDimmed: Bool
    let isInvalid: Bool
    let isLast: Bool
    let isConfirmed: Bool
    let action: () -> Void

    /// - Parameters:
    ///   - isDimmed: at the multi-select limit: still visible and announced, but unavailable.
    ///   - isLast: the answer last time; shown as an accent dot (quick chips).
    ///   - isConfirmed: just logged; green with a ✓ (quick chips, for ``QuickrTiming/chipConfirm``).
    public init(
        _ label: String, role: Role = .radio, style: ChipStyle = .form, isSelected: Bool = false,
        isDimmed: Bool = false, isInvalid: Bool = false, isLast: Bool = false, isConfirmed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.role = role
        self.style = style
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.isInvalid = isInvalid
        self.isLast = isLast
        self.isConfirmed = isConfirmed
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: style == .form ? 8 : 6) {
                if showsCheck { QIcon.check.view(size: 16, weight: .heavy) }
                Text(label)
                    .multilineTextAlignment(.center)
            }
            .font(style == .form ? .qr(.callout) : .qr(.sansSemiBold, size: 14.5, relativeTo: .callout))
            .padding(.horizontal, style == .form ? 12 : 8)
            .padding(.vertical, style == .form ? 8 : 6)
            .frame(maxWidth: .infinity, minHeight: style == .form ? QuickrMetrics.chipHeight : QuickrMetrics.tapTarget)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if isLast && !isConfirmed {
                    Circle().fill(Color.qr.accent).frame(width: 6, height: 6).padding(4)
                }
            }
            .qrShadow(.card, isActive: style == .form && isSelected)
            .contentShape(shape)
        }
        .buttonStyle(QuickrPressStyle(scale: 0.96))
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityAddTraits(traits)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isDimmed ? "Limit reached. Deselect another to choose this." : "")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: style == .form ? QuickrMetrics.chipRadius : QuickrMetrics.controlRadius, style: .continuous)
    }

    private var showsCheck: Bool { isConfirmed || (style == .form && isSelected) }

    private var foreground: Color {
        if isConfirmed { return .white }
        return isSelected ? .qr.onAccent : .qr.ink
    }

    private var background: Color {
        if isConfirmed { return .qr.ok }
        if isSelected { return .qr.accent }
        return style == .form ? .qr.surface : .qr.paper.opacity(0.6)
    }

    private var border: Color {
        if isConfirmed { return .qr.ok }
        if isSelected { return .qr.accent }
        return isInvalid ? .qr.danger.opacity(0.6) : .qr.lineStrong
    }

    private var traits: AccessibilityTraits {
        role != .button && isSelected ? [.isButton, .isSelected] : .isButton
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if role == .checkbox && !isSelected { parts.append("Not selected") }
        if isLast { parts.append("Same as last time") }
        if isConfirmed { parts.append("Logged") }
        return parts.joined(separator: ", ")
    }
}

/// Timings that define the logging feel.
public enum QuickrTiming {
    /// How long a tapped quick-log chip stays green (the Undo toast has the details).
    public static let chipConfirm: Duration = .milliseconds(1600)
}

/// Record-screen chips for one question: single select (radio) or multi select (checkbox,
/// with an optional limit that dims the rest).
public struct ChipGrid: View {
    private enum Mode {
        case single(Binding<String?>, required: Bool)
        case multi(Binding<[String]>, max: Int?)
    }

    let options: [ChipOption]
    private let mode: Mode
    let isInvalid: Bool
    @State private var tapCount = 0

    /// Single select. Tapping the selected chip clears it unless `required`.
    public init(options: [ChipOption], selection: Binding<String?>, required: Bool, isInvalid: Bool = false) {
        self.options = options
        self.mode = .single(selection, required: required)
        self.isInvalid = isInvalid
    }

    /// Multi select, kept in option order. With `max`, the remaining chips dim at the limit.
    public init(options: [ChipOption], selection: Binding<[String]>, max: Int? = nil, isInvalid: Bool = false) {
        self.options = options
        self.mode = .multi(selection, max: max)
        self.isInvalid = isInvalid
    }

    public var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.offset) { index, option in
                        chip(option)
                            .gridCellColumns(ChipSelection.isWide(index: index, count: options.count) ? 2 : 1)
                    }
                }
            }
        }
        .qrHaptic(.selection, trigger: tapCount)
    }

    private var rows: [[(offset: Int, element: ChipOption)]] {
        let items = Array(options.enumerated())
        return stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    @ViewBuilder
    private func chip(_ option: ChipOption) -> some View {
        switch mode {
        case .single(let selection, let required):
            Chip(option.label, role: .radio, isSelected: selection.wrappedValue == option.value, isInvalid: isInvalid) {
                selection.wrappedValue = ChipSelection.toggle(
                    selection.wrappedValue, tapped: option.value, required: required)
                tapCount += 1
            }
        case .multi(let selection, let max):
            let current = selection.wrappedValue
            let dimmed = ChipSelection.isDimmed(option.value, in: current, max: max)
            Chip(
                option.label, role: .checkbox, isSelected: current.contains(option.value), isDimmed: dimmed,
                isInvalid: isInvalid
            ) {
                guard !dimmed else { return }
                selection.wrappedValue = ChipSelection.toggle(
                    current, tapped: option.value, max: max, order: options.map(\.value))
                tapCount += 1
            }
        }
    }
}

/// The tile's quick-log chips: one tap logs. While `log` runs every chip is disabled; when it
/// succeeds, the tapped chip turns green with a ✓ for 1.6 s. The last answer carries a dot.
public struct QuickChipGrid: View {
    let options: [ChipOption]
    let last: String?
    let label: String
    let log: @MainActor (ChipOption) async -> Bool

    @State private var busy: String?
    @State private var confirmed: String?
    @State private var logCount = 0

    /// - Parameters:
    ///   - label: the group's accessible name, e.g. "Log Headache".
    ///   - log: logs the option and returns true when it was saved or queued.
    public init(
        options: [ChipOption], last: String?, label: String, log: @escaping @MainActor (ChipOption) async -> Bool
    ) {
        self.options = options
        self.last = last
        self.label = label
        self.log = log
    }

    public var body: some View {
        let columns = ChipSelection.quickColumns(count: options.count)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(options) { option in
                Chip(
                    option.label, role: .button, style: .quick, isLast: last == option.value,
                    isConfirmed: confirmed == option.value
                ) {
                    tap(option)
                }
                .disabled(busy != nil)
                .accessibilityLabel("Log \(option.label)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .qrHaptic(.logged, trigger: logCount)
        .task(id: confirmed) {
            guard confirmed != nil else { return }
            try? await Task.sleep(for: QuickrTiming.chipConfirm)
            confirmed = nil
        }
    }

    private func tap(_ option: ChipOption) {
        busy = option.value
        Task {
            let ok = await log(option)
            busy = nil
            if ok {
                confirmed = option.value
                logCount += 1
            }
        }
    }
}

private struct ChipsPreview: View {
    @State var single: String? = "mild"
    @State var multi: [String] = ["run", "yoga"]
    let severity = [
        ChipOption("none", label: "None"), ChipOption("mild", label: "Mild"),
        ChipOption("moderate", label: "Moderate"), ChipOption("severe", label: "Severe"),
    ]
    let workouts = [
        ChipOption("run", label: "Run"), ChipOption("strength", label: "Strength"), ChipOption("yoga", label: "Yoga"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChipGrid(options: severity, selection: $single, required: false)
            ChipGrid(options: workouts, selection: $multi, max: 2)
            QuickChipGrid(options: severity, last: "none", label: "Log Headache") { _ in
                try? await Task.sleep(for: .milliseconds(200))
                return true
            }
        }
        .padding()
        .background(Color.qr.paper)
    }
}

#Preview("Chips") { ChipsPreview() }
#endif
