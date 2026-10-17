#if os(iOS)
import SwiftUI

/// A big numeric field with − and + buttons sized for thumbs (the PWA's `NumberInput`).
/// The text stays editable; the buttons step by ``NumberStepRule/step`` and clamp to the range.
public struct NumberStepper: View {
    public enum Size: Sendable {
        /// Record screen: 52 pt buttons and field.
        case regular
        /// Tile quick-log: 44 pt.
        case compact

        var side: CGFloat { self == .regular ? QuickrMetrics.chipHeight : QuickrMetrics.tapTarget }
    }

    @Binding var text: String
    let rule: NumberStepRule
    let unit: String?
    let label: String
    let size: Size
    let isInvalid: Bool
    let focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @State private var haptic: (QuickrHaptic, Int) = (.increase, 0)

    /// - Parameters:
    ///   - label: the accessible name ("Glasses"); the visible label is the caller's.
    ///   - focus: lets a form drive focus; otherwise the stepper tracks its own.
    public init(
        text: Binding<String>, rule: NumberStepRule, unit: String? = nil, label: String, size: Size = .regular,
        isInvalid: Bool = false, focus: FocusState<Bool>.Binding? = nil
    ) {
        self._text = text
        self.rule = rule
        self.unit = unit
        self.label = label
        self.size = size
        self.isInvalid = isInvalid
        self.focus = focus
    }

    public var body: some View {
        HStack(spacing: size == .regular ? 8 : 6) {
            stepButton(.down)
            field
            stepButton(.up)
        }
        .frame(height: size.side)
        .sensoryFeedback(trigger: haptic.1) { _, _ in haptic.0.feedback }
    }

    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
        return TextField(text: $text, prompt: prompt) { Text(label) }
            .focused(focus ?? $ownFocus)
            .keyboardType(keyboard)
            .multilineTextAlignment(.center)
            .font(size == .regular ? .qr(.mono) : .qr(.monoSemiBold, size: 18, relativeTo: .title3))
            .monospacedDigit()
            .foregroundStyle(.qr.ink)
            .padding(.leading, 12)
            .padding(.trailing, unit == nil ? 12 : 52)
            .frame(maxHeight: .infinity)
            .background(Color.qr.surface, in: shape)
            .overlay(alignment: .trailing) {
                if let unit {
                    Text(unit)
                        .font(.qr(.sansMedium, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.qr.muted)
                        .padding(.trailing, 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .background(shape.inset(by: -3).fill(isFocused && !isInvalid ? Color.qr.accent.opacity(0.2) : .clear))
            .accessibilityValue(
                unit.map { text.isEmpty ? "Empty" : "\(text) \($0)" } ?? (text.isEmpty ? "Empty" : text)
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(.up)
                case .decrement: step(.down)
                @unknown default: break
                }
            }
    }

    private var prompt: Text {
        Text(rule.rangeHint ?? (rule.isInteger ? "0" : "0.0"))
            .font(.qr(.body))
            .foregroundStyle(.qr.muted.opacity(0.7))
    }

    private var borderColor: Color {
        if isInvalid { return .qr.danger }
        return isFocused ? .qr.accent : .qr.lineStrong
    }

    private var keyboard: UIKeyboardType {
        // The number pads have no minus key.
        if rule.allowsNegative { return .numbersAndPunctuation }
        return rule.isInteger ? .numberPad : .decimalPad
    }

    private func stepButton(_ direction: NumberStepRule.Direction) -> some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
        let enabled = rule.canBump(text, direction)
        return Button {
            step(direction)
        } label: {
            Text(direction == .up ? "+" : "−")
                .font(.qr(.sansSemiBold, size: 24, relativeTo: .title2))
                .foregroundStyle(.qr.inkSoft)
                .frame(width: size.side, height: size.side)
                .background(Color.qr.surface, in: shape)
                .overlay(shape.strokeBorder(Color.qr.lineStrong, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(QuickrPressStyle(scale: 0.95))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(direction == .up ? "Increase" : "Decrease")
    }

    private func step(_ direction: NumberStepRule.Direction) {
        guard rule.canBump(text, direction) else { return }
        text = rule.bumped(text, direction)
        haptic = (direction == .up ? .increase : .decrease, haptic.1 + 1)
    }
}

private struct StepperPreview: View {
    @State var minutes = "50"
    @State var distance = ""
    @State var glasses = "0"

    var body: some View {
        VStack(spacing: 16) {
            NumberStepper(
                text: $minutes, rule: NumberStepRule(integer: true, min: 0, max: 600), unit: "min", label: "Duration")
            NumberStepper(
                text: $distance, rule: NumberStepRule(integer: false, min: 0, decimals: 1), unit: "km",
                label: "Distance")
            NumberStepper(
                text: $glasses, rule: NumberStepRule(integer: true, min: 0, max: 20), label: "Glasses", size: .compact)
        }
        .padding()
        .background(Color.qr.paper)
    }
}

#Preview("Stepper") { StepperPreview() }
#endif
