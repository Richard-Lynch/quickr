import Foundation

/// Keys, slugs and text as the topic builder derives them and the server normalises them
/// (`frontend/src/lib/builder.ts`, `backend/app/schemas/questions.py`, `services/topics.py`).
public enum BuilderText {
    /// Pydantic's `str_strip_whitespace`, which the server applies to every question and topic
    /// string: Rust's `str::trim`, i.e. Unicode `White_Space`. Unlike Python's `str.strip()`
    /// (`ServerText`) it keeps U+001C–U+001F; unlike JS `trim()` (the PWA) it keeps U+FEFF.
    /// Checked against `shared/fixtures/builder-vectors.json`.
    public static func strip(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) }) ?? first
        return String(scalars[first...last])
    }

    /// Unicode `White_Space`.
    public static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }

    /// What the server compares labels by: stripped, then Python's `str.casefold()` (so "Straße"
    /// and "STRASSE" clash; the PWA's `toLocaleLowerCase` misses that).
    public static func fold(_ s: String) -> String {
        strip(s).folding(options: .caseInsensitive, locale: nil)
    }

    /// Characters as the server counts them: code points.
    public static func count(_ s: String) -> Int { s.unicodeScalars.count }

    /// "Hours slept (approx.)" → "hours_slept_approx" (`toSnakeKey`). Always a valid key or "".
    public static func snakeKey(_ label: String) -> String {
        var key = separated(stripDiacritics(label).lowercased(), by: "_")
        key = String(key.drop { $0 == "_" || $0.isASCII && $0.isNumber })
        return trimTrailing(String(key.prefix(63)), "_")
    }

    /// The server's `slugify` for a topic name: "Sleep Log — 2026" → "sleep-log-2026". Characters
    /// without an ASCII decomposition are dropped ("Straße" → "strae"). "" where the server would
    /// fall back to "topic": send no slug and let it.
    public static func slug(_ name: String) -> String {
        let ascii = name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)
        let slug = separated(String(String.UnicodeScalarView(ascii)).lowercased(), by: "-")
        return trimTrailing(String(slug.prefix(64)), "-")
    }

    /// The first of `base`, `base_2`, `base_3`, … not in `taken`, within 63 characters
    /// (`uniqueKey`). An empty base is "question".
    public static func uniqueKey(_ base: String, taken: some Sequence<String>) -> String {
        let used = Set(taken)
        let root = base.isEmpty ? "question" : base
        if !used.contains(root) { return root }
        var i = 2
        while true {
            let suffix = "_\(i)"
            let candidate = String(root.prefix(63 - suffix.count)) + suffix
            if !used.contains(candidate) { return candidate }
            i += 1
        }
    }

    /// NFKD without U+0300–U+036F (the PWA's `DIACRITICS`).
    private static func stripDiacritics(_ s: String) -> String {
        let kept = s.decomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            !(0x300...0x36F).contains($0.value)
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// Runs of anything but `[a-z0-9]` become one `separator`; none at either end.
    private static func separated(_ s: String, by separator: Character) -> String {
        var out = ""
        var pending = false
        for c in s.unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                if pending && !out.isEmpty { out.append(separator) }
                pending = false
                out.unicodeScalars.append(c)
            } else {
                pending = true
            }
        }
        return out
    }

    private static func trimTrailing(_ s: String, _ c: Character) -> String {
        var s = s
        while s.last == c { s.removeLast() }
        return s
    }
}

/// A server pattern from `GET /limits` (`key_pattern`, `slug_pattern`), matched against a whole
/// value. One that doesn't compile falls back to the snapshot's (`patternOf`).
struct ServerPattern {
    private let regex: Regex<AnyRegexOutput>?

    init(_ pattern: String, fallback: String) {
        regex = ((try? Regex(pattern)) ?? (try? Regex(fallback)))?.matchingSemantics(.unicodeScalar)
    }

    func matches(_ value: String) -> Bool {
        guard let regex else { return false }
        return (try? regex.wholeMatch(in: value)) != nil
    }
}
