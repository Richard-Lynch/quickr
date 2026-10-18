/// Text as the server normalises it (`services/answers.py::_normalise`): Python's `str.strip()`,
/// whose whitespace differs from JS `trim()`. It strips U+001C–U+001F and U+0085 and keeps
/// U+FEFF. Text and choice answers are stripped this way, so a value that validates is exactly
/// what the server stores; numbers are parsed with the PWA's JS trim (`NumberInput.parse`).
/// Checked against `shared/fixtures/answer-text-vectors.json`.
public enum ServerText {
    public static func strip(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) }) ?? first
        return String(scalars[first...last])
    }

    /// Python's `str.isspace()`.
    public static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }
}
