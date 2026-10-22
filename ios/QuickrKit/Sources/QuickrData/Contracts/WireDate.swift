import Foundation

/// The API's date-time format: the **quickR wire profile**, a deliberate subset of RFC 3339
/// agreed in sync-protocol.md §1.5. It is what the server (Python `datetime.isoformat()`) emits,
/// and anything outside it is a contract violation, not a format to be tolerated.
///
/// - **In:** `YYYY-MM-DDTHH:MM:SS`, then 0–6 fractional digits, then `Z` or `±HH:MM`. The server
///   sends microseconds and drops the fraction when it is zero, so both forms occur. Rejected:
///   a missing offset, 7 or more fractional digits (RFC 3339 allows any number), leap seconds
///   (`:60`, which RFC 3339 allows and Python never produces), `±HHMM` offsets and out-of-range
///   fields.
/// - **Out:** always UTC with an explicit `+00:00` offset; six fractional digits when the
///   instant has a sub-second part, none otherwise. Precision is one microsecond, like the server.
///
/// Hand-written rather than `ISO8601DateFormatter`, which needs a different configuration for
/// each fraction form and is not `Sendable`.
public enum WireDate {
    public static func parse(_ text: String) -> Date? {
        var scanner = Scanner(Array(text.utf8))
        guard let year = scanner.digits(4), scanner.take("-"), let month = scanner.digits(2), scanner.take("-"),
            let day = scanner.digits(2), scanner.take("T") || scanner.take("t"),
            let hour = scanner.digits(2), scanner.take(":"), let minute = scanner.digits(2), scanner.take(":"),
            let second = scanner.digits(2)
        else { return nil }
        var micros = 0
        if scanner.take(".") {
            var count = 0
            while let digit = scanner.digit() {
                guard count < 6 else { return nil }
                micros = micros * 10 + digit
                count += 1
            }
            guard count > 0 else { return nil }
            for _ in count..<6 { micros *= 10 }
        }
        let offsetSeconds: Int
        if scanner.take("Z") || scanner.take("z") {
            offsetSeconds = 0
        } else if let sign = scanner.sign(), let offsetHour = scanner.digits(2), scanner.take(":"),
            let offsetMinute = scanner.digits(2), offsetHour < 24, offsetMinute < 60
        {
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        } else {
            return nil
        }
        guard scanner.atEnd, year >= 1, (1...12).contains(month), day >= 1,
            day <= daysInMonth(year: year, month: month), hour < 24, minute < 60, second < 60
        else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + Double(micros) / 1_000_000)
    }

    public static func format(_ date: Date) -> String {
        let totalMicros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let (seconds, micros) = floorDivide(totalMicros, 1_000_000)
        let (days, secondOfDay) = floorDivide(seconds, 86_400)
        let (year, month, day) = civilFromDays(Int(days))
        let hour = Int(secondOfDay) / 3600
        let minute = Int(secondOfDay) % 3600 / 60
        let second = Int(secondOfDay) % 60
        var text = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
        text += "T" + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
        if micros != 0 { text += "." + pad(Int(micros), 6) }
        return text + "+00:00"
    }

    public static let decodingStrategy = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = parse(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not an RFC 3339 date-time with an offset: \(text)")
        }
        return date
    }

    public static let encodingStrategy = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(format(date))
    }

    // MARK: Calendar arithmetic (proleptic Gregorian, H. Hinnant's days_from_civil)

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        let remainder = ((value % divisor) + divisor) % divisor
        return ((value - remainder) / divisor, remainder)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index == bytes.count }

        mutating func take(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }

        mutating func digit() -> Int? {
            guard index < bytes.count, (48...57).contains(bytes[index]) else { return nil }
            defer { index += 1 }
            return Int(bytes[index]) - 48
        }

        mutating func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let digit = digit() else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        mutating func sign() -> Int? {
            if take("+") { return 1 }
            if take("-") { return -1 }
            return nil
        }
    }
}

/// JSON coders configured for the API: `WireDate` dates, explicit `CodingKeys` everywhere (no key
/// strategy, because answer maps and `option_counts` use snake_case keys that must not be
/// rewritten), and sorted keys out so encoded bodies are deterministic.
public enum WireCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = WireDate.decodingStrategy
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = WireDate.encodingStrategy
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
