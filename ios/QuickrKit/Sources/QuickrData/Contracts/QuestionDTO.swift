import QuickrCore

// Questions on the wire come in two shapes, as in `openapi.json`:
// - `QuestionDTO` (`*Question-Output`): responses and the store's `questions_json`. Every key is
//   required; nullable ones decode `null` and fail when missing (`RequiredKey`).
// - `QuestionInputDTO` (`*Question-Input`): request bodies. Defaulted keys may be omitted and are
//   left out when unset.

/// A question in a response, tagged by `type`.
public enum QuestionDTO: Codable, Sendable, Hashable {
    case int(IntQuestionDTO)
    case double(DoubleQuestionDTO)
    case str(StrQuestionDTO)
    case `enum`(EnumQuestionDTO)

    private enum TagKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TagKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "int": self = .int(try IntQuestionDTO(from: decoder))
        case "double": self = .double(try DoubleQuestionDTO(from: decoder))
        case "str": self = .str(try StrQuestionDTO(from: decoder))
        case "enum": self = .enum(try EnumQuestionDTO(from: decoder))
        case let tag:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown question type \(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var tag = encoder.container(keyedBy: TagKeys.self)
        switch self {
        case .int(let question):
            try tag.encode("int", forKey: .type)
            try question.encode(to: encoder)
        case .double(let question):
            try tag.encode("double", forKey: .type)
            try question.encode(to: encoder)
        case .str(let question):
            try tag.encode("str", forKey: .type)
            try question.encode(to: encoder)
        case .enum(let question):
            try tag.encode("enum", forKey: .type)
            try question.encode(to: encoder)
        }
    }
}

public struct IntQuestionDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    @RequiredKey public var helpText: String?
    public var required: Bool
    @RequiredKey public var min: Int?
    @RequiredKey public var max: Int?
    @RequiredKey public var unit: String?

    enum CodingKeys: String, CodingKey {
        case key, label, required, min, max, unit
        case helpText = "help_text"
    }
}

public struct DoubleQuestionDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    @RequiredKey public var helpText: String?
    public var required: Bool
    @RequiredKey public var min: Double?
    @RequiredKey public var max: Double?
    @RequiredKey public var decimals: Int?
    @RequiredKey public var unit: String?

    enum CodingKeys: String, CodingKey {
        case key, label, required, min, max, decimals, unit
        case helpText = "help_text"
    }
}

public struct StrQuestionDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    @RequiredKey public var helpText: String?
    public var required: Bool
    public var minLength: Int
    public var maxLength: Int
    public var multiline: Bool

    enum CodingKeys: String, CodingKey {
        case key, label, required, multiline
        case helpText = "help_text"
        case minLength = "min_length"
        case maxLength = "max_length"
    }
}

public struct EnumQuestionDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    @RequiredKey public var helpText: String?
    public var required: Bool
    public var options: [EnumOptionDTO]
    public var multiple: Bool
    @RequiredKey public var minSelected: Int?
    @RequiredKey public var maxSelected: Int?

    enum CodingKeys: String, CodingKey {
        case key, label, required, options, multiple
        case helpText = "help_text"
        case minSelected = "min_selected"
        case maxSelected = "max_selected"
    }
}

public struct EnumOptionDTO: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var archived: Bool
}

extension QuestionDTO: DomainConvertible {
    public func toDomain() -> Question {
        switch self {
        case .int(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required,
                kind: .int(.init(min: q.min, max: q.max, unit: q.unit)))
        case .double(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required,
                kind: .double(.init(min: q.min, max: q.max, decimals: q.decimals, unit: q.unit)))
        case .str(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required,
                kind: .string(.init(minLength: q.minLength, maxLength: q.maxLength, multiline: q.multiline)))
        case .enum(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required,
                kind: .choice(
                    .init(
                        options: q.options.map { $0.toDomain() }, multiple: q.multiple,
                        minSelected: q.minSelected, maxSelected: q.maxSelected)))
        }
    }

    /// The full DTO for a domain question, for example for `questions_json`.
    public init(_ question: Question) {
        switch question.kind {
        case .int(let rules):
            self = .int(
                IntQuestionDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, min: rules.min, max: rules.max, unit: rules.unit))
        case .double(let rules):
            self = .double(
                DoubleQuestionDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, min: rules.min, max: rules.max, decimals: rules.decimals,
                    unit: rules.unit))
        case .string(let rules):
            self = .str(
                StrQuestionDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, minLength: rules.minLength, maxLength: rules.maxLength,
                    multiline: rules.multiline))
        case .choice(let rules):
            self = .enum(
                EnumQuestionDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, options: rules.options.map(EnumOptionDTO.init),
                    multiple: rules.multiple, minSelected: rules.minSelected, maxSelected: rules.maxSelected))
        }
    }
}

extension EnumOptionDTO: DomainConvertible {
    public func toDomain() -> EnumOption { EnumOption(value: value, label: label, archived: archived) }

    public init(_ option: EnumOption) {
        self.init(value: option.value, label: option.label, archived: option.archived)
    }
}

// MARK: - Requests

/// A question in a request body (`TopicCreate`, `VersionCreate`, `VersionDraft`), tagged by
/// `type`. Decodes the input shape, where defaulted keys may be missing.
public enum QuestionInputDTO: Codable, Sendable, Hashable {
    case int(IntQuestionInputDTO)
    case double(DoubleQuestionInputDTO)
    case str(StrQuestionInputDTO)
    case `enum`(EnumQuestionInputDTO)

    private enum TagKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TagKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "int": self = .int(try IntQuestionInputDTO(from: decoder))
        case "double": self = .double(try DoubleQuestionInputDTO(from: decoder))
        case "str": self = .str(try StrQuestionInputDTO(from: decoder))
        case "enum": self = .enum(try EnumQuestionInputDTO(from: decoder))
        case let tag:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown question type \(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var tag = encoder.container(keyedBy: TagKeys.self)
        switch self {
        case .int(let question):
            try tag.encode("int", forKey: .type)
            try question.encode(to: encoder)
        case .double(let question):
            try tag.encode("double", forKey: .type)
            try question.encode(to: encoder)
        case .str(let question):
            try tag.encode("str", forKey: .type)
            try question.encode(to: encoder)
        case .enum(let question):
            try tag.encode("enum", forKey: .type)
            try question.encode(to: encoder)
        }
    }
}

public struct IntQuestionInputDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var helpText: String?
    public var required: Bool?
    public var min: Int?
    public var max: Int?
    public var unit: String?

    enum CodingKeys: String, CodingKey {
        case key, label, required, min, max, unit
        case helpText = "help_text"
    }
}

public struct DoubleQuestionInputDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var helpText: String?
    public var required: Bool?
    public var min: Double?
    public var max: Double?
    public var decimals: Int?
    public var unit: String?

    enum CodingKeys: String, CodingKey {
        case key, label, required, min, max, decimals, unit
        case helpText = "help_text"
    }
}

public struct StrQuestionInputDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var helpText: String?
    public var required: Bool?
    public var minLength: Int?
    public var maxLength: Int?
    public var multiline: Bool?

    enum CodingKeys: String, CodingKey {
        case key, label, required, multiline
        case helpText = "help_text"
        case minLength = "min_length"
        case maxLength = "max_length"
    }
}

public struct EnumQuestionInputDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var helpText: String?
    public var required: Bool?
    public var options: [EnumOptionInputDTO]
    public var multiple: Bool?
    public var minSelected: Int?
    public var maxSelected: Int?

    enum CodingKeys: String, CodingKey {
        case key, label, required, options, multiple
        case helpText = "help_text"
        case minSelected = "min_selected"
        case maxSelected = "max_selected"
    }
}

public struct EnumOptionInputDTO: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var archived: Bool?
}

extension QuestionInputDTO: DomainConvertible {
    /// Applies the server's defaults (`backend/app/schemas/questions.py`) to omitted keys.
    public func toDomain() -> Question {
        switch self {
        case .int(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required ?? true,
                kind: .int(.init(min: q.min, max: q.max, unit: q.unit)))
        case .double(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required ?? true,
                kind: .double(.init(min: q.min, max: q.max, decimals: q.decimals, unit: q.unit)))
        case .str(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required ?? true,
                kind: .string(
                    .init(
                        minLength: q.minLength ?? 0,
                        maxLength: q.maxLength ?? Question.StringRules.defaultMaxLength,
                        multiline: q.multiline ?? false)))
        case .enum(let q):
            Question(
                key: q.key, label: q.label, helpText: q.helpText, required: q.required ?? true,
                kind: .choice(
                    .init(
                        options: q.options.map {
                            EnumOption(value: $0.value, label: $0.label, archived: $0.archived ?? false)
                        },
                        multiple: q.multiple ?? false, minSelected: q.minSelected, maxSelected: q.maxSelected)))
        }
    }

    /// Every key set from a domain question; unset optionals are left out of the body.
    public init(_ question: Question) {
        switch question.kind {
        case .int(let rules):
            self = .int(
                IntQuestionInputDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, min: rules.min, max: rules.max, unit: rules.unit))
        case .double(let rules):
            self = .double(
                DoubleQuestionInputDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, min: rules.min, max: rules.max, decimals: rules.decimals,
                    unit: rules.unit))
        case .string(let rules):
            self = .str(
                StrQuestionInputDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required, minLength: rules.minLength, maxLength: rules.maxLength,
                    multiline: rules.multiline))
        case .choice(let rules):
            self = .enum(
                EnumQuestionInputDTO(
                    key: question.key, label: question.label, helpText: question.helpText,
                    required: question.required,
                    options: rules.options.map {
                        EnumOptionInputDTO(value: $0.value, label: $0.label, archived: $0.archived)
                    },
                    multiple: rules.multiple, minSelected: rules.minSelected, maxSelected: rules.maxSelected))
        }
    }
}
