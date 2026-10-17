/// JavaScript number semantics the PWA's validation depends on, so iOS accepts and prints numbers
/// exactly as `frontend/src/lib/answerSchema.ts` does (and as `backend/app/services/quicklog.py`
/// reproduces in Python). Every JS number is a `Double`; comparisons against bounds happen there.
public enum JSNumber {
    /// `Number.MAX_SAFE_INTEGER`: whole numbers beyond it are "too large" for an int answer.
    public static let maxSafeInteger: Double = 9_007_199_254_740_991

    /// `String(x)` for a JS number: ECMAScript `Number::toString` in radix 10. Shortest
    /// round-trip digits, positional for decimal exponents in [-7, 21), else `1.5e-7` / `1e+21`.
    /// `-0` prints as `0`.
    public static func string(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }
        if x == 0 { return "0" }
        if x < 0 { return "-" + string(-x) }

        // Swift's description is also the shortest round-trip form; only the layout differs.
        let text = x.description
        let parts = text.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1)
        let whole = String(mantissa[0])
        var digits = whole + (mantissa.count == 2 ? String(mantissa[1]) : "")
        // x = 0.digits × 10^n
        var n = whole.count + exponent
        while digits.hasPrefix("0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        let k = digits.count

        if k <= n && n <= 21 { return digits + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            return "\(digits[..<split]).\(digits[split...])"
        }
        if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + digits }
        let e = n - 1
        let head = k == 1 ? digits : "\(digits.prefix(1)).\(digits.dropFirst())"
        return "\(head)e\(e >= 0 ? "+" : "-")\(abs(e))"
    }

    /// `String.prototype.trim()`: JS WhiteSpace and LineTerminator code points.
    public static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isJSWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isJSWhitespace($0) }) ?? first
        return String(scalars[first...last])
    }

    static func isJSWhitespace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }
}

/// The PWA's number input grammar (`INT_RE`, `NUM_RE` and `parseNumberInput` in `answerSchema.ts`).
/// ASCII digits only, like JS `\d`.
public enum NumberInput {
    /// `[+-]?\d+`
    public static func isWholeNumber(_ s: String) -> Bool {
        var scanner = Scanner(s)
        scanner.sign()
        return scanner.digits() > 0 && scanner.atEnd
    }

    /// `[+-]?(\d+([.,]\d*)?|[.,]\d+)([eE][+-]?\d+)?`
    public static func isNumber(_ s: String) -> Bool {
        var scanner = Scanner(s)
        scanner.sign()
        let whole = scanner.digits()
        let separator = scanner.take { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ",") }
        let fraction = separator ? scanner.digits() : 0
        guard whole > 0 || fraction > 0 else { return false }
        if scanner.take({ $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
            scanner.sign()
            guard scanner.digits() > 0 else { return false }
        }
        return scanner.atEnd
    }

    /// What the user typed as a number: trimmed, `.` or `,` as the decimal separator, an optional
    /// sign and exponent. Nil for anything else, an empty string, or a non-finite result (`1e999`).
    public static func parse(_ raw: String) -> Double? {
        let s = JSNumber.trim(raw)
        guard isNumber(s) else { return nil }
        // The grammar allows at most one separator.
        guard let n = Double(s.replacingOccurrences(of: ",", with: ".")), n.isFinite else { return nil }
        return n
    }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0

        init(_ s: String) { bytes = Array(s.utf8) }

        var atEnd: Bool { i == bytes.count }

        mutating func take(_ match: (UInt8) -> Bool) -> Bool {
            guard i < bytes.count, match(bytes[i]) else { return false }
            i += 1
            return true
        }

        mutating func sign() {
            _ = take { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }
        }

        mutating func digits() -> Int {
            let start = i
            while take({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {}
            return i - start
        }
    }
}
