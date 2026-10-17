import Foundation

/// The rules behind ``NumberStepper``: parsing, ± bumps clamped to the range, and formatting.
/// Mirrors the PWA's `NumberInput` (`frontend/src/components/answers/AnswerField.tsx`).
/// Platform-neutral so the host `swift test` covers it.
public struct NumberStepRule: Hashable, Sendable {
    public enum Direction: Sendable {
        case down
        case up
    }

    public var min: Double?
    public var max: Double?
    /// Fixed decimal places for a double question, or nil for free precision. Ignored for ints.
    public var decimals: Int?
    public var isInteger: Bool

    public init(integer: Bool, min: Double? = nil, max: Double? = nil, decimals: Int? = nil) {
        self.isInteger = integer
        self.min = min
        self.max = max
        self.decimals = integer ? 0 : decimals
    }

    /// 1 for ints and free-precision doubles, otherwise one unit in the last decimal place.
    public var step: Double {
        guard !isInteger, let decimals else { return 1 }
        return pow(10, -Double(decimals))
    }

    /// Negative values need a keyboard with a minus key.
    public var allowsNegative: Bool { min.map { $0 < 0 } ?? true }

    /// Parses what the user typed: optional sign, `.` or `,` as the decimal separator, exponent.
    /// Returns nil for anything else, including an empty string.
    public func parse(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard s.wholeMatch(of: Self.numberPattern) != nil else { return nil }
        guard let n = Double(s.replacingOccurrences(of: ",", with: ".")), n.isFinite else { return nil }
        return n
    }

    /// The text after one tap on − or +. An empty or unparsable field starts from the bound:
    /// + goes to `min` (or 0), − goes to `max` (or `min`, or 0). The result is always clamped.
    public func bumped(_ text: String, _ direction: Direction) -> String {
        let sign: Double = direction == .up ? 1 : -1
        var value: Double
        if let current = parse(text) {
            value = current + sign * step
        } else {
            value = direction == .up ? (min ?? 0) : (max ?? min ?? 0)
        }
        return format(clamped(value))
    }

    /// False once the current value sits at (or beyond) the bound in that direction.
    public func canBump(_ text: String, _ direction: Direction) -> Bool {
        guard let current = parse(text) else { return true }
        switch direction {
        case .down: return min.map { current > $0 } ?? true
        case .up: return max.map { current < $0 } ?? true
        }
    }

    public func clamped(_ value: Double) -> Double {
        var v = value
        if let min { v = Swift.max(min, v) }
        if let max { v = Swift.min(max, v) }
        return v
    }

    /// Ints round; fixed decimals pad (`2.50`); free precision trims float noise (`0.30000000000000004` → `0.3`).
    public func format(_ value: Double) -> String {
        // "%.0f" never traps, unlike Int(_:), which does for values outside Int's range (a
        // pasted 1e30). Doubles cannot overflow here: `parse` rejects non-finite input and the
        // largest finite Double plus a step stays finite.
        if isInteger { return Self.zeroless(String(format: "%.0f", locale: Self.posix, value.rounded())) }
        if let decimals { return String(format: "%.\(decimals)f", locale: Self.posix, value) }
        return Self.plain(value)
    }

    /// The placeholder for an empty field: "0–10", "≥ 0", "≤ 5", or nil without bounds.
    public var rangeHint: String? {
        switch (min, max) {
        case (let lo?, let hi?): "\(Self.plain(lo))–\(Self.plain(hi))"
        case (let lo?, nil): "≥ \(Self.plain(lo))"
        case (nil, let hi?): "≤ \(Self.plain(hi))"
        case (nil, nil): nil
        }
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
    nonisolated(unsafe) private static let numberPattern = /[+-]?(\d+([.,]\d*)?|[.,]\d+)([eE][+-]?\d+)?/

    /// Shortest plain rendering: no exponent, no trailing zeros, at most 10 decimal places.
    static func plain(_ value: Double) -> String {
        var s = String(format: "%.10f", locale: posix, value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return zeroless(s)
    }

    private static func zeroless(_ s: String) -> String { s == "-0" ? "0" : s }
}
