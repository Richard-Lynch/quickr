import Foundation
import QuickrCore

/// The "Other value…" text input of a number reminder (notifications.md §7.3).
public enum NotificationNumberInput {
    /// Parses what the user typed against the reminder's descriptor:
    /// 1. trim, and drop a trailing unit (case-insensitive);
    /// 2. then parse and validate as `parseQuickNumber` does (the app's own number tiles): `,` or
    ///    `.` as the one decimal separator, no grouping, finite, an integer for `int`, within
    ///    `min`…`max`. Like it (and the server), extra fraction digits beyond `decimals` are
    ///    accepted: `decimals` is a display hint (§4.4), whatever §7.3 step 4 says.
    /// Returns the answer to log, or the validation message.
    public static func parse(_ raw: String, for number: QuickLogDescriptor.Number) -> Result<AnswerValue, AnswerMessage>
    {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let unit = number.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty,
            text.count > unit.count, text.lowercased().hasSuffix(unit.lowercased())
        {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let question = question(for: number)
        switch QuickLog.parseNumber(text, for: question) {
        case .success(let answers):
            guard let value = answers[number.key] else { return .failure("Enter a number") }
            return .success(value)
        case .failure(let message):
            return .failure(message)
        }
    }

    /// The question the descriptor stands for, with its bounds and decimals.
    static func question(for number: QuickLogDescriptor.Number) -> Question {
        let kind: Question.Kind
        if number.type == "int" {
            kind = .int(.init(min: number.min.flatMap(int), max: number.max.flatMap(int), unit: number.unit))
        } else {
            kind = .double(
                .init(
                    min: number.min.map(double), max: number.max.map(double), decimals: number.decimals,
                    unit: number.unit))
        }
        return Question(key: number.key, label: number.label, kind: kind)
    }

    private static func int(_ n: QuickLogNumber) -> Int? {
        switch n {
        case .int(let value): value
        case .double(let x): Int(exactly: x)
        }
    }

    private static func double(_ n: QuickLogNumber) -> Double {
        switch n {
        case .int(let value): Double(value)
        case .double(let x): x
        }
    }
}
