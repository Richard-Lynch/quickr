import CryptoKit
import Foundation
import QuickrCore

/// A topic's reminder category, computed on the device exactly as the server does
/// (notifications.md §2.3, §4; B7's `backend/app/services/notification_categories.py`), so a
/// category registered here matches the `aps.category` of every push. Checked against
/// `shared/fixtures/notification-vectors.json` (N1).
public struct NotificationCategory: Sendable, Hashable {
    /// `quickr.t.{topic_id}.{hash}`
    public var id: String
    public var descriptor: QuickLogDescriptor
    public var actions: [Action]

    /// One action of the category, in the vectors' (and `actions_json`'s) shape.
    public struct Action: Codable, Sendable, Hashable {
        /// `log`, `input` or `open`
        public var kind: String
        /// `q1|…` (§4.2)
        public var identifier: String
        public var title: String
        /// `input` only.
        public var textInputButtonTitle: String?
        public var textInputPlaceholder: String?

        public init(
            kind: String, identifier: String, title: String, textInputButtonTitle: String? = nil,
            textInputPlaceholder: String? = nil
        ) {
            self.kind = kind
            self.identifier = identifier
            self.title = title
            self.textInputButtonTitle = textInputButtonTitle
            self.textInputPlaceholder = textInputPlaceholder
        }

        enum CodingKeys: String, CodingKey {
            case kind, identifier, title
            case textInputButtonTitle = "text_input_button_title"
            case textInputPlaceholder = "text_input_placeholder"
        }

        /// As registered with the system: nil for a kind this build doesn't know.
        public var spec: NotificationActionSpec? {
            switch kind {
            case "log": NotificationActionSpec(id: identifier, title: title, kind: .log)
            case "open": NotificationActionSpec(id: identifier, title: title, kind: .open)
            case "input":
                NotificationActionSpec(
                    id: identifier, title: title,
                    kind: .input(
                        buttonTitle: textInputButtonTitle ?? "Log", placeholder: textInputPlaceholder ?? "Value"))
            default: nil
            }
        }
    }

    /// The most options a reminder lists before "More…" (§2.3).
    public static let shownOptions = 4
    /// With 5–6 options: the 3 most-used, then "More…".
    public static let mostUsedOptions = 3
    /// Labels and units are cut to this many Unicode scalars, the last one "…".
    public static let maxLabelLength = 64

    /// The category of a topic's current version, or nil when the topic logs through the record
    /// screen (no category: tapping opens it).
    /// - Parameters:
    ///   - counts: answers per option value of the quick-log question, over the topic's entries
    ///     (only used to pick the 3 shown options of a 5–6 option enum).
    ///   - last: the latest answer to the quick-log question, by `captured_at` then entry id.
    public init?(
        serverId: String, topicId: String, version: Int, questions: [Question], counts: [String: Int] = [:],
        last: AnswerValue? = nil
    ) {
        guard let descriptor = Self.descriptor(questions: questions, counts: counts, last: last) else { return nil }
        self.init(serverId: serverId, topicId: topicId, version: version, descriptor: descriptor)
    }

    /// The category of a descriptor (a push's `quick_log`, or one computed with ``descriptor``).
    public init(serverId: String, topicId: String, version: Int, descriptor: QuickLogDescriptor) {
        self.descriptor = descriptor
        actions = Self.actions(serverId: serverId, topicId: topicId, version: version, descriptor: descriptor)
        id = "quickr.t.\(topicId).\(Self.hash(actions))"
    }

    /// The text appended to the alert body when options are cut: " · 3 of 6 shown, More for all".
    public var bodySuffix: String {
        guard case .choice(let choice) = descriptor, choice.totalOptions > choice.options.count else { return "" }
        return " · \(choice.options.count) of \(choice.totalOptions) shown, More for all"
    }

    /// As registered with the system.
    public var spec: NotificationCategorySpec {
        NotificationCategorySpec(id: id, actions: actions.compactMap(\.spec))
    }

    // MARK: - Descriptor (§2.3)

    /// The server's `quick_log` descriptor for a topic's questions; nil when not quick-loggable.
    public static func descriptor(questions: [Question], counts: [String: Int], last: AnswerValue?)
        -> QuickLogDescriptor?
    {
        guard let quick = QuickLog(questions: questions) else { return nil }
        switch quick {
        case .chips(let question, let options):
            var shown = options
            if options.count > shownOptions {
                // The 3 most-used, most-used first; ties keep the question's order (a stable sort).
                shown = options.enumerated()
                    .sorted { a, b in
                        let (ca, cb) = (counts[a.element.value] ?? 0, counts[b.element.value] ?? 0)
                        return ca != cb ? ca > cb : a.offset < b.offset
                    }
                    .prefix(mostUsedOptions).map(\.element)
            }
            return .choice(
                .init(
                    key: question.key, label: cut(question.label),
                    options: shown.map { .init(value: $0.value, label: cut($0.label)) }, totalOptions: options.count))
        case .number(let question):
            // The question's own bounds, not `numericRules` (doubles): an int's are exact.
            switch question.kind {
            case .int(let rules):
                return .number(
                    .init(
                        type: "int", key: question.key, label: cut(question.label), unit: unit(rules.unit),
                        min: rules.min.map(QuickLogNumber.int), max: rules.max.map(QuickLogNumber.int), decimals: nil,
                        lastValue: lastInt(last, min: rules.min, max: rules.max)))
            case .double(let rules):
                return .number(
                    .init(
                        type: "double", key: question.key, label: cut(question.label), unit: unit(rules.unit),
                        min: rules.min.map(QuickLogNumber.double), max: rules.max.map(QuickLogNumber.double),
                        decimals: rules.decimals, lastValue: lastDouble(last, min: rules.min, max: rules.max)))
            case .string, .choice:
                return nil
            }
        }
    }

    /// `last_value` of an int question: an int, or a whole double, within the bounds, compared as
    /// integers (a binary64 can't tell 2^53 + 3 from 2^53 + 4).
    static func lastInt(_ last: AnswerValue?, min: Int?, max: Int?) -> QuickLogNumber? {
        let n: Int
        switch last {
        case .int(let value): n = value
        case .double(let x):
            guard x.isFinite, x == x.rounded(), let value = Int(exactly: x) else { return nil }
            n = value
        default: return nil
        }
        if let min, n < min { return nil }
        if let max, n > max { return nil }
        return .int(n)
    }

    /// `last_value` of a double question: any finite number within the bounds. `decimals` never
    /// drops or rounds it.
    static func lastDouble(_ last: AnswerValue?, min: Double?, max: Double?) -> QuickLogNumber? {
        let x: Double
        switch last {
        case .int(let value): x = Double(value)
        case .double(let value): x = value
        default: return nil
        }
        guard x.isFinite else { return nil }
        if let min, x < min { return nil }
        if let max, x > max { return nil }
        return .double(x)
    }

    /// An empty unit is none; a long one is cut.
    private static func unit(_ unit: String?) -> String? {
        unit.flatMap { $0.isEmpty ? nil : cut($0) }
    }

    /// Cut to ``maxLabelLength`` Unicode scalars, the last one replaced by "…".
    static func cut(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxLabelLength else { return text }
        var cut = String.UnicodeScalarView(scalars.prefix(maxLabelLength - 1))
        cut.append("…")
        return String(cut)
    }

    // MARK: - Actions (§4.1, §4.2)

    static func actions(serverId: String, topicId: String, version: Int, descriptor: QuickLogDescriptor) -> [Action] {
        func id(_ key: String, _ k: ActionIdentifier.Kind, _ value: String = "") -> String {
            ActionIdentifier(serverId: serverId, topicId: topicId, version: version, key: key, kind: k, value: value)
                .description
        }
        switch descriptor {
        case .choice(let choice):
            var actions = choice.options.map {
                Action(kind: "log", identifier: id(choice.key, .option, $0.value), title: $0.label)
            }
            if choice.totalOptions > choice.options.count {
                actions.append(Action(kind: "open", identifier: id(choice.key, .more), title: "More…"))
            }
            return actions
        case .number(let number):
            var actions: [Action] = []
            if let last = number.lastValue {
                let text = NumberFormat.fmt(last)
                actions.append(
                    Action(
                        kind: "log", identifier: id(number.key, .number, text),
                        title: "Log \(text)" + (number.unit.map { " \($0)" } ?? "")))
            }
            actions.append(
                Action(
                    kind: "input", identifier: id(number.key, .input), title: "Other value…",
                    textInputButtonTitle: "Log", textInputPlaceholder: number.unit.map { "Value in \($0)" } ?? "Value"))
            return actions
        }
    }

    // MARK: - Hash (§4.3)

    /// The hash input: "quickr-cat-v1", then per action U+001E kind U+001F identifier U+001F title
    /// (and U+001F button title U+001F placeholder for `input`), NFC-normalised.
    static func hashInput(_ actions: [Action]) -> String {
        var input = "quickr-cat-v1"
        for action in actions {
            input += "\u{1E}\(action.kind)\u{1F}\(action.identifier)\u{1F}\(action.title)"
            if action.kind == "input" {
                input += "\u{1F}\(action.textInputButtonTitle ?? "")\u{1F}\(action.textInputPlaceholder ?? "")"
            }
        }
        return input.precomposedStringWithCanonicalMapping
    }

    /// The first 16 lowercase hex digits of SHA-256(UTF-8(hash input)).
    static func hash(_ actions: [Action]) -> String {
        SHA256.hash(data: Data(hashInput(actions).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// `q1|{server_id}|{topic_id}|{version}|{key}|{k}|{value}` (notifications.md §4.2).
public struct ActionIdentifier: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case option = "o"
        case number = "n"
        case input = "i"
        case more = "m"
    }

    public var serverId: String
    public var topicId: String
    public var version: Int
    public var key: String
    public var kind: Kind
    /// `o`: the option value; `n`: `fmt(last_value)`; `i`, `m`: empty.
    public var value: String

    public init(serverId: String, topicId: String, version: Int, key: String, kind: Kind, value: String = "") {
        self.serverId = serverId
        self.topicId = topicId
        self.version = version
        self.key = key
        self.kind = kind
        self.value = value
    }

    public var description: String {
        ["q1", serverId, topicId, String(version), key, kind.rawValue, value].joined(separator: "|")
    }

    /// Parses an action identifier, or nil when it isn't a well-formed `q1` one: lowercase
    /// canonical UUIDs, a decimal version, a valid key, a known kind and a value that fits it.
    /// An option value may itself contain `|`: everything after the sixth bar is the value.
    public init?(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, parts[0] == "q1", Self.isCanonicalUUID(parts[1]), Self.isCanonicalUUID(parts[2]),
            let version = Self.decimal(parts[3]), Self.isKey(parts[4]), let kind = Kind(rawValue: parts[5])
        else { return nil }
        let value = parts[6]
        switch kind {
        case .option: guard !value.isEmpty else { return nil }
        case .number: guard NumberFormat.isCanonical(value) else { return nil }
        case .input, .more: guard value.isEmpty else { return nil }
        }
        self.init(serverId: parts[1], topicId: parts[2], version: version, key: parts[4], kind: kind, value: value)
    }

    /// Whether this action belongs to the reminder it came with (§7.1 step 1): same server, topic,
    /// version and key, and a value the descriptor offers. A tampered identifier fails.
    public func matches(_ info: QuickrNotificationInfo) -> Bool {
        guard serverId == info.serverId, topicId == info.topicId, version == info.version,
            let quickLog = info.quickLog, key == quickLog.key
        else { return false }
        switch (kind, quickLog) {
        case (.option, .choice(let choice)): return choice.options.contains { $0.value == value }
        case (.more, .choice(let choice)): return choice.totalOptions > choice.options.count
        case (.number, .number(let number)): return number.lastValue.map(NumberFormat.fmt) == value
        case (.input, .number): return true
        default: return false
        }
    }

    static func isCanonicalUUID(_ text: String) -> Bool {
        guard let uuid = UUID(uuidString: text) else { return false }
        return uuid.uuidString.lowercased() == text
    }

    private static func decimal(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), text == "0" || !text.hasPrefix("0") else { return nil }
        return Int(text)
    }

    static func isKey(_ text: String) -> Bool {
        // \A…\z: the whole string, whatever a regex engine's `$` does before a final newline.
        text.range(of: #"\A[a-z][a-z0-9_]{0,62}\z"#, options: .regularExpression) != nil
    }
}

/// `fmt` (notifications.md §4.4): an int in base 10; a double as its shortest round-trip decimal,
/// written positionally (no exponent), with no trailing zeros or dot, and never "-0". No rounding:
/// `decimals` is not used. The separator is always ".".
public enum NumberFormat {
    public static func fmt(_ number: QuickLogNumber) -> String {
        switch number {
        case .int(let n): String(n)
        case .double(let x): fmt(x)
        }
    }

    public static func fmt(_ x: Double) -> String {
        precondition(x.isFinite, "fmt of a non-finite number")
        if x == 0 { return "0" }
        // Swift's description is the shortest round-trip decimal ("1.5e-07", "1e+21", "7.0").
        var text = "\(x.magnitude)"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...])!
            text = String(text[..<e])
        }
        let point = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
        var digits = text.replacingOccurrences(of: ".", with: "")
        // Position of the decimal point within `digits`, after applying the exponent. (Swift writes
        // at most one leading zero, "0.3", which the positional forms below keep as it is.)
        let pointAt = point + exponent
        // Trailing zeros of the fraction ("7.0" → "7").
        while digits.count > 1, digits.last == "0", digits.count > pointAt { digits.removeLast() }
        let out: String
        if pointAt <= 0 {
            out = "0." + String(repeating: "0", count: -pointAt) + digits
        } else if pointAt >= digits.count {
            out = digits + String(repeating: "0", count: pointAt - digits.count)
        } else {
            let i = digits.index(digits.startIndex, offsetBy: pointAt)
            out = digits[..<i] + "." + digits[i...]
        }
        return (x < 0 ? "-" : "") + out
    }

    /// Whether `text` is a `fmt` output (what an `n` action id carries): an optional "-", digits
    /// with an optional fraction, no exponent, no leading zeros, no trailing zeros, no "-0".
    public static func isCanonical(_ text: String) -> Bool {
        text.range(of: #"\A-?(0|[1-9][0-9]*)(\.[0-9]*[1-9])?\z"#, options: .regularExpression) != nil && text != "-0"
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
