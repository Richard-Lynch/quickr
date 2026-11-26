import Foundation

/// A variable being edited (`DraftVariable` in `frontend/src/lib/builder.ts`, timers2.md §1.1):
/// a name alert expressions refer to (`t`, `rest`) and a duration typed as `m:ss` or `h:mm:ss`.
public struct DraftVariable: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Lowercased on entry (``withName(_:)``); the server stores names lowercase.
    public var name: String
    /// The duration as typed (``DurationText``).
    public var duration: String

    public init(id: UUID = UUID(), name: String, duration: String) {
        self.id = id
        self.name = name
        self.duration = duration
    }

    /// The name as entered (`withVariableName`): lowercased.
    public func withName(_ name: String) -> DraftVariable {
        var variable = self
        variable.name = name.lowercased()
        return variable
    }

    /// The variable's rules (`convertDraftVariable`, timers2.md §1.3): a name (lowercased; the
    /// pattern; not a unit) and a duration of at most 7 days.
    public func validated(limits: Limits = .serverDefaults) -> Result<TopicTimer.Variable, DraftIssues<VariableField>> {
        var issues: [DraftIssue<VariableField>] = []
        let name = BuilderText.strip(self.name).lowercased()
        if name.isEmpty {
            issues.append(.init(field: .name, message: BuilderMessage.required))
        } else if !Self.isName(name, maxLength: limits.maxVarNameLength) {
            issues.append(
                .init(
                    field: .name,
                    message: "Use a–z, 0–9, _ (start with a letter, max \(limits.maxVarNameLength))"))
        } else if Self.reserved.contains(name) {
            issues.append(
                .init(field: .name, message: "'\(name)' is a unit (ms, s, m, h) and can't be a variable name"))
        }
        let ms = DurationText.parse(duration)
        if JSNumber.trim(duration).isEmpty {
            issues.append(.init(field: .duration, message: BuilderMessage.required))
        } else if ms == nil {
            issues.append(.init(field: .duration, message: "Enter m:ss or h:mm:ss"))
        } else if let ms, ms > TimerExpr.maxMs {
            issues.append(.init(field: .duration, message: "At most 7 days"))
        }
        guard issues.isEmpty, let ms else { return .failure(DraftIssues(issues)) }
        return .success(TopicTimer.Variable(name: name, ms: ms))
    }

    /// The units of §2.1, which can't be variable names (`2m` and `2*m` would read alike).
    static let reserved: Set<String> = ["ms", "s", "m", "h"]

    /// `^[a-z][a-z0-9_]{0,max-1}$` (`VarName`, lowercase).
    static func isName(_ name: String, maxLength: Int) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, scalars.count <= maxLength, ("a"..."z").contains(first) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The draft's variables an alert can use (`usableVariables`): the valid ones, the first of a
    /// repeated name, in order.
    static func usable(_ variables: [DraftVariable], limits: Limits) -> [(name: String, ms: Int)] {
        var out: [(name: String, ms: Int)] = []
        for variable in variables {
            if case .success(let v) = variable.validated(limits: limits), !out.contains(where: { $0.name == v.name }) {
                out.append((v.name, v.ms))
            }
        }
        return out
    }
}

/// A field of one draft variable, where a validation message belongs.
public enum VariableField: String, Sendable, Hashable {
    case name, duration
}

/// A variable's duration as the editor reads and shows it (`parseDurationText`, `durationText`).
public enum DurationText {
    /// `m:ss` or `h:mm:ss` (the seconds may carry up to three decimals) as whole ms, surrounding
    /// space ignored; nil when it isn't one, or is past 2^53 - 1 ms.
    public static func parse(_ text: String) -> Int? {
        let trimmed = JSNumber.trim(text)
        var main = Substring(trimmed)
        var fraction = 0
        if let dot = trimmed.firstIndex(of: ".") {
            let digits = trimmed[trimmed.index(after: dot)...]
            guard (1...3).contains(digits.count), digits.allSatisfy(isDigit) else { return nil }
            fraction = Int(digits.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
            main = trimmed[..<dot]
        }
        let parts = main.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(isDigit) else { return nil }
        for part in parts.dropFirst() {
            guard part.count == 2, part.allSatisfy(isDigit), let tens = part.first, tens <= "5" else { return nil }
        }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        let n = numbers.map { $0 ?? 0 }
        let (hours, minutes, seconds) = n.count == 3 ? (n[0], n[1], n[2]) : (0, n[0], n[1])
        var total = hours
        for (factor, add) in [(60, minutes), (60, seconds), (1000, fraction)] {
            let (product, over) = total.multipliedReportingOverflow(by: factor)
            let (sum, over2) = product.addingReportingOverflow(add)
            if over || over2 { return nil }
            total = sum
        }
        return Double(total) <= JSNumber.maxSafeInteger ? total : nil
    }

    /// `m:ss` or `h:mm:ss` (`fmtDuration`), with the ms when it has any: `1:30.500`.
    public static func format(_ ms: Int) -> String {
        let rest = ms % 1000
        guard rest != 0 else { return DurationFormat.format(ms) }
        let digits = String(rest)
        return "\(DurationFormat.format(ms)).\(String(repeating: "0", count: Swift.max(0, 3 - digits.count)))\(digits)"
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}

extension TopicDraft {
    public func variableIndex(of id: DraftVariable.ID) -> Int? { variables.firstIndex { $0.id == id } }

    /// Whether another variable fits (`max_variables`).
    public func canAddVariable(limits: Limits = .serverDefaults) -> Bool { variables.count < limits.maxVariables }

    /// Appends a new, empty variable and returns its id.
    @discardableResult
    public mutating func addVariable() -> DraftVariable.ID {
        let variable = DraftVariable(name: "", duration: "")
        variables.append(variable)
        return variable.id
    }

    /// Names a variable, lowercased on entry.
    public mutating func setVariableName(_ id: DraftVariable.ID, _ name: String) {
        guard let i = variableIndex(of: id) else { return }
        variables[i] = variables[i].withName(name)
    }

    /// Sets a variable's duration, as typed.
    public mutating func setVariableDuration(_ id: DraftVariable.ID, _ duration: String) {
        guard let i = variableIndex(of: id) else { return }
        variables[i].duration = duration
    }

    public mutating func removeVariable(_ id: DraftVariable.ID) {
        guard let i = variableIndex(of: id) else { return }
        variables.remove(at: i)
    }
}
