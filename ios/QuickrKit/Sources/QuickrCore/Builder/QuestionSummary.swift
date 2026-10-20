import Foundation

/// The versions list's text for a published question (`frontend/src/lib/questionSummary.ts`).
/// Checked in en-US against `shared/fixtures/builder-ui-vectors.json`.
public enum QuestionSummary {
    /// `constraintText`: "0–10 · kg · 1 dp", "5–2000 chars · multiline", "2 options · 1 archived".
    public static func constraint(_ question: Question, locale: Locale = .autoupdatingCurrent) -> String {
        func number(_ value: Double) -> String { ChartFormat.number(value, locale: locale) }
        func range(_ min: Double?, _ max: Double?) -> String? {
            switch (min, max) {
            case (let min?, let max?): "\(number(min))–\(number(max))"
            case (let min?, nil): "≥ \(number(min))"
            case (nil, let max?): "≤ \(number(max))"
            case (nil, nil): nil
            }
        }
        switch question.kind {
        case .int(let rules):
            let parts = [range(rules.min.map(Double.init), rules.max.map(Double.init)), nonEmpty(rules.unit)]
            return joined(parts)
        case .double(let rules):
            let parts = [range(rules.min, rules.max), nonEmpty(rules.unit), rules.decimals.map { "\($0) dp" }]
            return joined(parts)
        case .string(let rules):
            return "\(rules.minLength)–\(rules.maxLength) chars\(rules.multiline ? " · multiline" : "")"
        case .choice(let rules):
            let active = rules.options.count { !$0.archived }
            let archived = rules.options.count - active
            return "\(active) option\(active == 1 ? "" : "s")\(archived > 0 ? " · \(archived) archived" : "")"
        }
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    private static func joined(_ parts: [String?]) -> String {
        let text = parts.compactMap(\.self).joined(separator: " · ")
        return text.isEmpty ? "any value" : text
    }
}
