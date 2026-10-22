/// Which control a question gets and what it offers (the logic half of the PWA's `inputHints`).
/// Rendering lives in QuickrUI.
extension Question {
    /// Most options rendered as tappable chips for a single-select; more use a picker (`CHIP_LIMIT`).
    public static let chipLimit = 6

    /// The options a choice control shows, in order: the active ones, plus archived ones in `keep`
    /// (editing an entry that holds them) labelled "(retired)". Empty for other types.
    public func visibleOptions(keeping keep: Set<String> = []) -> [EnumOption] {
        guard case .choice(let rules) = kind else { return [] }
        return rules.options.compactMap { option in
            guard option.archived else { return option }
            guard keep.contains(option.value) else { return nil }
            return EnumOption(value: option.value, label: "\(option.label) (retired)", archived: true)
        }
    }

    /// A single-select with more active options than `chipLimit` uses a picker instead of chips.
    /// Multi-selects are always chips.
    public var usesChoicePicker: Bool {
        guard case .choice(let rules) = kind, !rules.multiple else { return false }
        return rules.activeOptions.count > Self.chipLimit
    }

    /// Bounds and precision of an int or double question, as doubles (the PWA compares that way).
    /// Nil for other types. Feed it to QuickrUI's `NumberStepRule`.
    public var numericRules: NumericRules? {
        switch kind {
        case .int(let rules):
            NumericRules(
                isInteger: true, min: rules.min.map(Double.init), max: rules.max.map(Double.init), decimals: 0,
                unit: rules.unit)
        case .double(let rules):
            NumericRules(isInteger: false, min: rules.min, max: rules.max, decimals: rules.decimals, unit: rules.unit)
        case .string, .choice:
            nil
        }
    }
}

/// See `Question.numericRules`.
public struct NumericRules: Sendable, Hashable {
    public var isInteger: Bool
    public var min: Double?
    public var max: Double?
    /// 0 for ints; nil for a double with free precision.
    public var decimals: Int?
    public var unit: String?

    public init(isInteger: Bool, min: Double?, max: Double?, decimals: Int?, unit: String?) {
        self.isInteger = isInteger
        self.min = min
        self.max = max
        self.decimals = decimals
        self.unit = unit
    }

    /// Negative values need a keyboard with a minus key.
    public var allowsNegative: Bool { min.map { $0 < 0 } ?? true }
}
