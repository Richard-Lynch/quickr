/// The four question types. `enum` covers single- and multi-select (`Question.ChoiceRules.multiple`).
public enum QuestionType: String, Sendable, Hashable, CaseIterable, Codable {
    case int
    case double
    case str
    case `enum`
}

/// One question of a topic version. `key` is its identity across versions.
public struct Question: Sendable, Hashable {
    public var key: String
    public var label: String
    public var helpText: String?
    public var required: Bool
    public var kind: Kind

    public init(key: String, label: String, helpText: String? = nil, required: Bool = true, kind: Kind) {
        self.key = key
        self.label = label
        self.helpText = helpText
        self.required = required
        self.kind = kind
    }

    public var type: QuestionType {
        switch kind {
        case .int: .int
        case .double: .double
        case .string: .str
        case .choice: .enum
        }
    }

    /// The type and its constraints. Defaults match the server's (`backend/app/schemas/questions.py`).
    public enum Kind: Sendable, Hashable {
        case int(IntRules)
        case double(DoubleRules)
        case string(StringRules)
        case choice(ChoiceRules)
    }

    /// Whole numbers; `min` and `max` are inclusive.
    public struct IntRules: Sendable, Hashable {
        public var min: Int?
        public var max: Int?
        public var unit: String?

        public init(min: Int? = nil, max: Int? = nil, unit: String? = nil) {
            self.min = min
            self.max = max
            self.unit = unit
        }
    }

    /// Decimal numbers; `min` and `max` are inclusive, `decimals` is a display and input hint.
    public struct DoubleRules: Sendable, Hashable {
        public var min: Double?
        public var max: Double?
        public var decimals: Int?
        public var unit: String?

        public init(min: Double? = nil, max: Double? = nil, decimals: Int? = nil, unit: String? = nil) {
            self.min = min
            self.max = max
            self.decimals = decimals
            self.unit = unit
        }
    }

    /// Free text, measured in characters.
    public struct StringRules: Sendable, Hashable {
        public static let defaultMaxLength = 500

        public var minLength: Int
        public var maxLength: Int
        public var multiline: Bool

        public init(minLength: Int = 0, maxLength: Int = Self.defaultMaxLength, multiline: Bool = false) {
            self.minLength = minLength
            self.maxLength = maxLength
            self.multiline = multiline
        }
    }

    /// A choice from `options`. `minSelected` and `maxSelected` only apply when `multiple` is true.
    public struct ChoiceRules: Sendable, Hashable {
        public var options: [EnumOption]
        public var multiple: Bool
        public var minSelected: Int?
        public var maxSelected: Int?

        public init(options: [EnumOption], multiple: Bool = false, minSelected: Int? = nil, maxSelected: Int? = nil) {
            self.options = options
            self.multiple = multiple
            self.minSelected = minSelected
            self.maxSelected = maxSelected
        }

        /// The options a new answer may pick, in display order.
        public var activeOptions: [EnumOption] { options.filter { !$0.archived } }
    }
}

/// One option of a choice question. Archived options stay valid in history but can't be picked.
public struct EnumOption: Sendable, Hashable {
    public var value: String
    public var label: String
    public var archived: Bool

    public init(value: String, label: String, archived: Bool = false) {
        self.value = value
        self.label = label
        self.archived = archived
    }
}
