import Foundation

/// Alert expressions (timers2.md §2): `t/2`, `t+30s`, `1.5m`.
///
/// A port of backend/app/services/timer_expr.py, the reference (the PWA's `lib/runs/timerExpr.ts`
/// is the other port); `shared/fixtures/timer-expr-vectors.json` is the contract.
///
/// ```
/// expr     := term { ('+' | '-') term }
/// term     := factor { ('*' | '/') factor }
/// factor   := duration | number | ident | '(' expr ')' | '-' factor
/// duration := number unit          unit := 'ms' | 's' | 'm' | 'h'
/// number   := digit { digit } [ '.' digit { digit } ]
/// ident    := letter { letter | digit | '_' }
/// ```
///
/// Evaluation runs in three stages and reports the first error it meets: the length (at most
/// `maxLength` code points), the whole parse (the leftmost `syntax` error; tokens are read
/// lazily), then the tree on doubles in evaluation order (the left operand, the right operand,
/// then the operator's checks: `type`, `div_zero`, then `too_long` for a duration beyond
/// `maxMs`). Last, on the untruncated result: a number is `type` at 0, below 0 is `negative` at
/// 0. The result is truncated toward zero to whole ms. Positions count Unicode code points.
public enum TimerExpr {
    /// Characters (Unicode code points) of an expression.
    public static let maxLength = 64
    /// 7 days: the bound on the result and on every duration on the way.
    public static let maxMs = 7 * 24 * 3_600_000

    /// An expression that does not evaluate: `code` (§2.3), `pos` (a 0-based code-point offset)
    /// and a human `detail`. `description` is the 422 message of timers2.md §1.3.
    public struct ExprError: Error, Sendable, Hashable, CustomStringConvertible {
        public enum Code: String, Sendable, Hashable, CaseIterable {
            case syntax
            case unknownVariable = "unknown_variable"
            case type
            case negative
            case tooLong = "too_long"
            case divZero = "div_zero"
        }

        public var code: Code
        public var pos: Int
        public var detail: String

        public init(code: Code, pos: Int, detail: String) {
            self.code = code
            self.pos = pos
            self.detail = detail
        }

        public var description: String { "\(code.rawValue) at \(pos): \(detail)" }
    }

    /// The whole ms `text` evaluates to over `variables` (lowercase name → ms, as stored).
    /// `maxLength`: the length limit (the builder passes `GET /limits`' `max_expr_length`).
    public static func evaluate(
        _ text: String, variables: [String: Int], maxLength: Int = TimerExpr.maxLength
    ) throws(ExprError) -> Int {
        let chars = Array(text.unicodeScalars)
        if chars.count > maxLength {
            throw ExprError(code: .tooLong, pos: maxLength, detail: "longer than \(maxLength) characters")
        }
        var parser = try Parser(chars)
        let tree = try parser.parse()
        let (value, duration) = try evaluateNode(tree, variables)
        if !duration {
            throw ExprError(code: .type, pos: 0, detail: "the result is a number: add a unit (ms, s, m or h)")
        }
        if value < 0 { throw ExprError(code: .negative, pos: 0, detail: "the result is below 0") }
        return Int(value)  // toward zero
    }

    // MARK: - Tokens

    struct Token {
        enum Kind { case number, duration, ident, op, end }
        var kind: Kind
        var pos: Int
        var text: String = ""
        var value: Double = 0
    }

    static let unitMs: [(unit: String, ms: Double)] = [("ms", 1), ("s", 1_000), ("m", 60_000), ("h", 3_600_000)]

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\r" || c == "\n" }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
    static func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
    static func isIdent(_ c: Unicode.Scalar) -> Bool { isLetter(c) || isDigit(c) || c == "_" }

    /// Python's `repr()` of one code point: the server spells an unknown character this way in its
    /// 422 message (`'\\xa0'`, `'\\u200b'`, `"'"`), so the builder shows the same text.
    static func pyRepr(_ c: Unicode.Scalar) -> String {
        let body: String
        switch c {
        case "\\": body = "\\\\"
        case "\t": body = "\\t"
        case "\n": body = "\\n"
        case "\r": body = "\\r"
        case "'": return "\"'\""
        default:
            if c != " " && !isPrintable(c) {
                let hex = String(c.value, radix: 16)
                let (prefix, width) = c.value < 0x100 ? ("x", 2) : c.value < 0x10000 ? ("u", 4) : ("U", 8)
                body = "\\" + prefix + String(repeating: "0", count: width - hex.count) + hex
            } else {
                body = String(c)
            }
        }
        return "'\(body)'"
    }

    /// Python's `str.isprintable()` for one code point: not Other (Cc, Cf, Cs, Co, Cn) or a
    /// Separator (Zl, Zp, Zs; the space is handled by the caller).
    static func isPrintable(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator,
            .spaceSeparator:
            false
        default: true
        }
    }

    /// Reads one token at a time, so the leftmost error is the one reported.
    struct Lexer {
        let text: [Unicode.Scalar]
        var i = 0

        init(_ text: [Unicode.Scalar]) { self.text = text }

        func string(_ from: Int, _ to: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: text[from..<to])
            return String(s)
        }

        mutating func next() throws(ExprError) -> Token {
            let n = text.count
            while i < n, isWhitespace(text[i]) { i += 1 }
            let start = i
            if start == n { return Token(kind: .end, pos: start) }
            let c = text[start]
            if isDigit(c) { return number(start) }
            if isLetter(c) {
                var j = start + 1
                while j < n, isIdent(text[j]) { j += 1 }
                i = j
                return Token(kind: .ident, pos: start, text: string(start, j))
            }
            if "+-*/()".unicodeScalars.contains(c) {
                i = start + 1
                return Token(kind: .op, pos: start, text: String(c))
            }
            throw ExprError(code: .syntax, pos: start, detail: "unknown character \(pyRepr(c))")
        }

        /// `number [unit]`, matched longest-first: `1.` is the number 1 (the `.` is the next,
        /// unknown, character) and `30sec` is `30s` followed by the identifier `ec`.
        mutating func number(_ start: Int) -> Token {
            let n = text.count
            var j = start
            while j < n, isDigit(text[j]) { j += 1 }
            if j + 1 < n, text[j] == ".", isDigit(text[j + 1]) {
                j += 1
                while j < n, isDigit(text[j]) { j += 1 }
            }
            let literal = string(start, j)
            let value = Double(literal) ?? 0
            for (unit, ms) in unitMs {
                let u = Array(unit.unicodeScalars)
                if j + u.count <= n, Array(text[j..<(j + u.count)]) == u {
                    i = j + u.count
                    return Token(kind: .duration, pos: start, text: string(start, i), value: value * ms)
                }
            }
            i = j
            return Token(kind: .number, pos: start, text: literal, value: value)
        }
    }

    // MARK: - Tree

    indirect enum Node {
        case leaf(Token)
        case neg(Node)
        case binary(op: String, pos: Int, left: Node, right: Node)
    }

    struct Parser {
        var lexer: Lexer
        var token: Token
        var previousEnd = -1
        var previousNumeric = false

        init(_ text: [Unicode.Scalar]) throws(ExprError) {
            lexer = Lexer(text)
            token = try lexer.next()
        }

        mutating func advance() throws(ExprError) -> Token {
            let t = token
            previousEnd = lexer.i
            previousNumeric = t.kind == .number || t.kind == .duration
            token = try lexer.next()
            return t
        }

        func unexpected() -> ExprError {
            if token.kind == .end {
                return ExprError(
                    code: .syntax, pos: token.pos, detail: token.pos == 0 ? "empty expression" : "unexpected end")
            }
            if token.kind == .ident, previousEnd == token.pos, previousNumeric {
                return ExprError(
                    code: .syntax, pos: token.pos, detail: "unknown unit '\(token.text)' (use ms, s, m or h)")
            }
            return ExprError(code: .syntax, pos: token.pos, detail: "unexpected '\(token.text)'")
        }

        func isOp(_ ops: String) -> Bool { token.kind == .op && ops.contains(token.text) }

        mutating func parse() throws(ExprError) -> Node {
            let node = try expr()
            if token.kind != .end { throw unexpected() }
            return node
        }

        mutating func expr() throws(ExprError) -> Node {
            var node = try term()
            while isOp("+-") {
                let op = try advance()
                node = .binary(op: op.text, pos: op.pos, left: node, right: try term())
            }
            return node
        }

        mutating func term() throws(ExprError) -> Node {
            var node = try factor()
            while isOp("*/") {
                let op = try advance()
                node = .binary(op: op.text, pos: op.pos, left: node, right: try factor())
            }
            return node
        }

        mutating func factor() throws(ExprError) -> Node {
            switch token.kind {
            case .number, .duration, .ident:
                return .leaf(try advance())
            case .op where isOp("-"):
                _ = try advance()
                return .neg(try factor())
            case .op where isOp("("):
                _ = try advance()
                let node = try expr()
                if !isOp(")") { throw unexpected() }
                _ = try advance()
                return node
            default:
                throw unexpected()
            }
        }
    }

    // MARK: - Evaluation

    static func bounded(_ value: Double, _ duration: Bool) throws(ExprError) -> (Double, Bool) {
        if duration, abs(value) > Double(maxMs) {
            throw ExprError(code: .tooLong, pos: 0, detail: "longer than 7 days")
        }
        return (value, duration)
    }

    static func typeName(_ duration: Bool) -> String { duration ? "duration" : "number" }

    /// `(value, isDuration)`; durations are ms.
    static func evaluateNode(_ node: Node, _ variables: [String: Int]) throws(ExprError) -> (Double, Bool) {
        switch node {
        case .leaf(let token):
            if token.kind == .ident {
                guard let ms = variables[token.text.lowercased()] else {
                    throw ExprError(code: .unknownVariable, pos: token.pos, detail: "unknown variable '\(token.text)'")
                }
                return try bounded(Double(ms), true)
            }
            return try bounded(token.value, token.kind == .duration)
        case .neg(let operand):
            let (value, duration) = try evaluateNode(operand, variables)
            return (-value, duration)
        case .binary(let op, let pos, let leftNode, let rightNode):
            let (left, leftDur) = try evaluateNode(leftNode, variables)
            let (right, rightDur) = try evaluateNode(rightNode, variables)
            switch op {
            case "+", "-":
                if leftDur != rightDur {
                    throw ExprError(code: .type, pos: pos, detail: "\(typeName(leftDur)) \(op) \(typeName(rightDur))")
                }
                return try bounded(op == "+" ? left + right : left - right, leftDur)
            case "*":
                if leftDur && rightDur { throw ExprError(code: .type, pos: pos, detail: "duration * duration") }
                return try bounded(left * right, leftDur || rightDur)
            default:
                if rightDur { throw ExprError(code: .type, pos: pos, detail: "\(typeName(leftDur)) / duration") }
                if right == 0 { throw ExprError(code: .divZero, pos: pos, detail: "division by zero") }
                return try bounded(left / right, leftDur)
            }
        }
    }
}
