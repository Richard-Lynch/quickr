import Foundation

/// The entry summary line (docs/specs/content-display.md §1): one line of at most
/// ``maxLength`` grapheme clusters describing an entry, timing first, then `label: value` per
/// answered question, joined by ``separator``. A port of `backend/app/services/summary.py`,
/// pinned to the same text by `shared/fixtures/entry-summary-vectors.json`
/// (`EntrySummaryVectorTests`).
public enum EntrySummary {
    public static let maxLength = 80
    public static let separator = " · "
    public static let ellipsis = "…"
    public static let defaultDecimals = 3

    /// §1.2: the timing part (if timed), then `label: text` for each of the entry's version's
    /// `questions` in their order (a key without a question is skipped, and so is an answer
    /// without text), joined by ``separator`` and truncated. `""` means "nothing to say";
    /// callers show their own fallback.
    public static func line(
        answers: [String: AnswerValue], timing: Timing?, questions: [Question], timer: TopicTimer?
    ) -> String {
        var parts: [String] = []
        if let timing { parts.append(timingLine(timing, timer: timer)) }
        for question in questions {
            // An empty text is nothing to say too (an option whose value or label is "").
            guard let answer = answers[question.key], let text = answerText(answer, for: question), !text.isEmpty
            else { continue }
            parts.append("\(question.label): \(text)")
        }
        return truncate(parts.joined(separator: separator))
    }

    /// ``line(answers:timing:questions:timer:)`` of `entry`; `""` for no entry.
    public static func line(entry: Entry?, questions: [Question], timer: TopicTimer?) -> String {
        guard let entry else { return "" }
        return line(answers: entry.answers, timing: entry.timing, questions: questions, timer: timer)
    }

    /// `"12:40"`, `"12:40 · 3 laps"` or, with typed laps, `"12:40 · Run 3 · Rest 3"`: the active
    /// duration, then the lap segments counted by type in the timer's declared order (then first
    /// seen), the untyped remainder last. Pauses, steps and skips are not shown.
    public static func timingLine(_ timing: Timing, timer: TopicTimer?) -> String {
        let laps = timing.segments.filter { $0.kind == .lap }
        return timingLine(activeMs: timing.activeMs, lapTypes: laps.map(lapType), declared: declaredLapTypes(timer))
    }

    /// The timing part from the active time, each lap's type (nil when untyped) and the timer's
    /// `(key, label)` lap types in declared order.
    static func timingLine(activeMs: Int, lapTypes: [String?], declared: [(key: String, label: String)]) -> String {
        var text = DurationFormat.format(activeMs)
        guard !lapTypes.isEmpty else { return text }
        let typed = lapTypes.compactMap { $0 }.filter { !$0.isEmpty }
        guard !typed.isEmpty else { return text + separator + laps(lapTypes.count) }
        // A key declared twice takes its last label, as the reference's `dict(...)` does.
        let labels = [String: String](declared.map { ($0.key, $0.label) }, uniquingKeysWith: { _, last in last })
        var keys: [String] = []
        for key in declared.map(\.key) + typed where typed.contains(key) && !keys.contains(key) {
            keys.append(key)
        }
        for key in keys {
            text += "\(separator)\(labels[key] ?? key) \(typed.count(where: { $0 == key }))"
        }
        let untyped = lapTypes.count - typed.count
        if untyped > 0 { text += separator + laps(untyped) }
        return text
    }

    /// One answer as display text, or nil when there is nothing to show for it (an empty
    /// selection, a blank string, or an answer whose shape doesn't fit the question).
    ///
    /// The domain keeps a single-select `enum` answer and a `str` answer as the same `.string`,
    /// so unlike the reference a `.string` under the other question type is shown, not skipped.
    public static func answerText(_ value: AnswerValue, for question: Question) -> String? {
        switch (question.kind, value) {
        case (.int(let rules), .int(let n)):
            withUnit(String(n), rules.unit)
        case (.int(let rules), .double(let x)):
            withUnit(number(x, decimals: 0), rules.unit)
        case (.double(let rules), .int(let n)):
            withUnit(String(n), rules.unit)
        case (.double(let rules), .double(let x)):
            withUnit(number(x, decimals: rules.decimals ?? defaultDecimals), rules.unit)
        case (.choice(let rules), .string(let v)):
            optionLabel(rules, v)
        case (.choice(let rules), .strings(let vs)):
            // A single-select that became multi-select keeps its old answers and the other way
            // round, so a choice question takes both shapes.
            nonEmpty(vs.map { optionLabel(rules, $0) }.joined(separator: ", "))
        case (.string, .string(let s)):
            collapsingWhitespace(s)
        default:
            nil
        }
    }

    /// Keeps the first `maxLength - 1` clusters and appends `…` when the line has more than
    /// ``maxLength``; no word boundary, and never inside a cluster (a flag, a keycap, a ZWJ
    /// sequence or a base with combining marks stays whole). `Character` is the extended
    /// grapheme cluster (UAX #29), the reference's `regex` `\X`.
    public static func truncate(_ line: String) -> String {
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength - 1)) + ellipsis
    }

    /// `value` with at most `decimals` fraction digits, rounded half away from zero from its
    /// shortest round-trip decimal (`description`, the reference's `repr`), trailing zeros and a
    /// bare point dropped, no thousands grouping. Digit arithmetic on the decimal string, so
    /// `1.005` is `1.01` and `36.65` is `36.7` (binary rounding would give `1` and `36.6`).
    static func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return value.description }
        let decimals = max(0, decimals)
        let description = value.magnitude.description  // "36.65", "1e-05", "1.2345e+20"
        let mantissa: Substring
        var exponent = 0
        if let e = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = description[..<e]
            exponent = Int(description[description.index(after: e)...]) ?? 0
        } else {
            mantissa = Substring(description)
        }
        let point = mantissa.firstIndex(of: ".")
        let whole = point.map { mantissa[..<$0] } ?? mantissa
        let fraction = point.map { mantissa[mantissa.index(after: $0)...] } ?? ""
        // The value is 0.d₁d₂…dₙ × 10^pointPosition.
        var digits = (whole + fraction).map { Int($0.asciiValue! - 48) }
        let pointPosition = whole.count + exponent
        // Digits kept: everything up to `decimals` places after the point.
        let keep = pointPosition + decimals
        var scaled: [Int]  // value × 10^decimals, rounded, most significant first
        if keep < 0 {
            scaled = [0]
        } else {
            let roundUp = keep < digits.count && digits[keep] >= 5
            if keep < digits.count {
                digits.removeSubrange(keep...)
            } else {
                digits += Array(repeating: 0, count: keep - digits.count)
            }
            scaled = digits.isEmpty ? [0] : digits
            if roundUp {
                var i = scaled.count - 1
                while i >= 0 && scaled[i] == 9 {
                    scaled[i] = 0
                    i -= 1
                }
                if i >= 0 { scaled[i] += 1 } else { scaled.insert(1, at: 0) }
            }
        }
        if scaled.count <= decimals { scaled = Array(repeating: 0, count: decimals - scaled.count + 1) + scaled }
        let integerDigits = scaled[..<(scaled.count - decimals)].drop { $0 == 0 }
        var fractionDigits = Array(scaled[(scaled.count - decimals)...])
        while fractionDigits.last == 0 { fractionDigits.removeLast() }
        var text = integerDigits.isEmpty ? "0" : integerDigits.map(String.init).joined()
        if !fractionDigits.isEmpty { text += "." + fractionDigits.map(String.init).joined() }
        // The sign of the value, as the reference's Decimal keeps it ("-0" for -0.0001 at 3).
        return value.sign == .minus ? "-" + text : text
    }

    /// Runs of Unicode `White_Space` (the vectors' `meta.whitespace`) collapsed to one space and
    /// trimmed; nil when nothing is left. Works on scalars, as the reference does on code
    /// points, so a space that a combining mark joins into one `Character` still collapses.
    static func collapsingWhitespace(_ s: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in s.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace && !scalars.isEmpty { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        return scalars.isEmpty ? nil : String(scalars)
    }

    private static func withUnit(_ text: String, _ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return text }
        return "\(text) \(unit)"
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    private static func optionLabel(_ rules: Question.ChoiceRules, _ value: String) -> String {
        rules.options.first { $0.value == value }?.label ?? value
    }

    private static func laps(_ n: Int) -> String { n == 1 ? "\(n) lap" : "\(n) laps" }

    // Lap types are M1's (timers2.md: `TimingSegment.lap_type`, `Timer.laps`), not in the Swift
    // models yet, so every lap reads as untyped. When M1 lands these become `segment.lapType` and
    // `timer?.laps.map { ($0.key, $0.label) } ?? []`, and M4-STATS adds the typed vectors.
    private static func lapType(_ segment: RunSegment) -> String? { nil }

    private static func declaredLapTypes(_ timer: TopicTimer?) -> [(key: String, label: String)] { [] }
}
