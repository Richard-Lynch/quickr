/// A local copy of the server's version-compatibility rules (`backend/app/services/compat.py`),
/// to warn while editing. `POST …/versions/check` stays authoritative: publish from its report.
///
/// Questions are identified by key across the whole history:
/// - a key's type never changes (use a new key);
/// - enum option values are never removed (archive them);
/// - a multi-select never becomes single-select;
/// - everything else is allowed, with warnings where existing data may not fit.
///
/// Messages and details are the server's, word for word. Python visits option sets in hash order;
/// here removed options follow the old order, added and changed ones the new order.
public enum CompatibilityCheck {
    /// Compares `proposed` with the latest version and every earlier one. `history` is oldest
    /// first; with only the latest version, a key removed earlier and re-added with another type
    /// isn't caught (the server will).
    public static func report(history: [[Question]], proposed: [Question]) -> CompatibilityReport {
        let current = history.last ?? []
        let currentByKey = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        // The latest definition of every key ever published.
        var ever: [String: Question] = [:]
        for version in history {
            for q in version { ever[q.key] = q }
        }

        var issues: [CompatibilityReport.Issue] = []
        var changes: [CompatibilityReport.Change] = []

        for q in proposed {
            let prior = ever[q.key]
            if let prior, prior.type != q.type {
                issues.append(
                    .init(
                        level: .error, questionKey: q.key,
                        message: "type cannot change (\(prior.type.rawValue) -> \(q.type.rawValue)); use a new key"))
                continue
            }
            if let old = currentByKey[q.key] {
                let details = diff(old, q, &issues)
                if !details.isEmpty { changes.append(.init(kind: .modified, questionKey: q.key, details: details)) }
            } else if let prior {
                changes.append(.init(kind: .restored, questionKey: q.key, details: diff(prior, q, &issues)))
            } else {
                changes.append(.init(kind: .added, questionKey: q.key, details: []))
                if q.required {
                    issues.append(
                        .init(
                            level: .info, questionKey: q.key,
                            message: "new required question; existing entries will show it as unanswered"))
                }
            }
        }

        let proposedKeys = Set(proposed.map(\.key))
        for q in current where !proposedKeys.contains(q.key) {
            changes.append(.init(kind: .removed, questionKey: q.key, details: []))
            issues.append(
                .init(
                    level: .warning, questionKey: q.key,
                    message: "removed from new entries; historic answers are kept and still aggregated"))
        }

        let commonOld = current.map(\.key).filter { proposedKeys.contains($0) }
        let commonNew = proposed.map(\.key).filter { currentByKey[$0] != nil }
        if commonOld != commonNew { changes.append(.init(kind: .reordered, questionKey: "*", details: [])) }

        if changes.isEmpty { issues.append(.init(level: .error, questionKey: nil, message: "no changes to publish")) }

        return CompatibilityReport(
            ok: !issues.contains { $0.level == .error }, nextVersion: history.count + 1, issues: issues,
            changes: changes)
    }

    private static func diff(_ old: Question, _ new: Question, _ issues: inout [CompatibilityReport.Issue]) -> [String]
    {
        var details: [String] = []
        let key = new.key
        func change(_ name: String, _ a: String, _ b: String) {
            if a != b { details.append("\(name): \(a) -> \(b)") }
        }
        func warn(_ message: String) { issues.append(.init(level: .warning, questionKey: key, message: message)) }

        change("label", old.label, new.label)
        change("help_text", fmt(old.helpText), fmt(new.helpText))
        change("required", fmt(old.required), fmt(new.required))
        if !old.required && new.required { warn("now required; existing entries without an answer are kept as-is") }

        let rangeTightened = "range tightened; historic answers outside it remain valid for their version"
        switch (old.kind, new.kind) {
        case (.int(let a), .int(let b)):
            change("min", fmt(a.min), fmt(b.min))
            change("max", fmt(a.max), fmt(b.max))
            change("unit", fmt(a.unit), fmt(b.unit))
            if tightened(a.min, a.max, b.min, b.max) { warn(rangeTightened) }
        case (.double(let a), .double(let b)):
            change("min", fmt(a.min), fmt(b.min))
            change("max", fmt(a.max), fmt(b.max))
            change("unit", fmt(a.unit), fmt(b.unit))
            change("decimals", fmt(a.decimals), fmt(b.decimals))
            if tightened(a.min, a.max, b.min, b.max) { warn(rangeTightened) }
        case (.string(let a), .string(let b)):
            change("min_length", String(a.minLength), String(b.minLength))
            change("max_length", String(a.maxLength), String(b.maxLength))
            change("multiline", fmt(a.multiline), fmt(b.multiline))
            if b.maxLength < a.maxLength || b.minLength > a.minLength {
                warn("length limits tightened; historic answers remain valid for their version")
            }
        case (.choice(let a), .choice(let b)):
            change("multiple", fmt(a.multiple), fmt(b.multiple))
            change("min_selected", fmt(a.minSelected), fmt(b.minSelected))
            change("max_selected", fmt(a.maxSelected), fmt(b.maxSelected))
            if a.multiple && !b.multiple {
                issues.append(
                    .init(
                        level: .error, questionKey: key,
                        message: "a multi-select question cannot become single-select; use a new key"))
            } else if !a.multiple && b.multiple {
                warn("now multi-select; historic single answers count as one-option selections")
            } else if b.multiple
                && ((b.minSelected ?? 0) > (a.minSelected ?? 0)
                    || b.maxSelected.map { hi in a.maxSelected.map { hi < $0 } ?? true } ?? false)
            {
                warn("selection limits tightened; historic answers remain valid for their version")
            }
            diffOptions(a.options, b.options, key: key, &details, &issues)
        default:
            break
        }
        return details
    }

    private static func diffOptions(
        _ old: [EnumOption], _ new: [EnumOption], key: String, _ details: inout [String],
        _ issues: inout [CompatibilityReport.Issue]
    ) {
        let oldByValue = Dictionary(old.map { ($0.value, $0) }, uniquingKeysWith: { $1 })
        let newByValue = Dictionary(new.map { ($0.value, $0) }, uniquingKeysWith: { $1 })
        for o in old where newByValue[o.value] == nil {
            details.append("option removed: \(o.value)")
            issues.append(
                .init(
                    level: .error, questionKey: key,
                    message: "option '\(o.value)' cannot be removed; archive it instead"))
        }
        for n in new where oldByValue[n.value] == nil { details.append("option added: \(n.value)") }
        for n in new {
            guard let o = oldByValue[n.value] else { continue }
            if o.label != n.label { details.append("option \(n.value) label: \(o.label) -> \(n.label)") }
            if o.archived != n.archived {
                details.append("option \(n.value) \(n.archived ? "archived" : "unarchived")")
            }
        }
        if old.map(\.value).filter({ newByValue[$0] != nil }) != new.map(\.value).filter({ oldByValue[$0] != nil }) {
            details.append("options reordered")
        }
    }

    private static func tightened<T: Comparable>(_ oldMin: T?, _ oldMax: T?, _ newMin: T?, _ newMax: T?) -> Bool {
        let lower = newMin.map { n in oldMin.map { n > $0 } ?? true } ?? false
        let upper = newMax.map { n in oldMax.map { n < $0 } ?? true } ?? false
        return lower || upper
    }

    // Python's `str()` of the value, or "none" (`_fmt`).
    private static func fmt(_ v: String?) -> String { v ?? "none" }
    private static func fmt(_ v: Bool) -> String { v ? "True" : "False" }
    private static func fmt(_ v: Int?) -> String { v.map(String.init) ?? "none" }

    /// A double as the server prints it after receiving it from iOS: `JSONEncoder` sends a whole
    /// number below 1e16 as an integer (`7`), anything else as Python's `repr` prints it
    /// (`3.5`, `1e-05`, `1e+20`), which Swift's `description` matches.
    private static func fmt(_ v: Double?) -> String {
        guard let v else { return "none" }
        if v == 0 { return "0" }
        let text = v.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
