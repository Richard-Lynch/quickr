/// Puts a server `Problem` back on a form, like `frontend/src/api/errors.ts` (`locToPath`,
/// `cleanMessage`, `mapApiError`) and the PWA entry form's field resolver.
public enum ProblemMapping {
    private static let roots: Set<String> = ["body", "query", "path", "header"]
    private static let questionTags: Set<String> = ["int", "double", "str", "enum"]
    private static let scheduleTags: Set<String> = ["daily", "interval"]

    /// A server `loc` relative to the request body: drops a leading `body` root and the tags of
    /// tagged unions, should any slip through. `["body", "questions", 0, "int", "min"]` →
    /// `["questions", 0, "min"]`.
    public static func bodyLocation(_ location: [FieldIssue.PathComponent]) -> [FieldIssue.PathComponent] {
        var out: [FieldIssue.PathComponent] = []
        for (i, component) in location.enumerated() {
            guard case .key(let key) = component else {
                out.append(component)
                continue
            }
            if i == 0 && roots.contains(key) { continue }
            let previous = i > 0 ? location[i - 1] : nil
            if questionTags.contains(key), case .index = previous { continue }
            if scheduleTags.contains(key), previous == .key("schedule") { continue }
            out.append(component)
        }
        return out
    }

    /// The dotted form of `bodyLocation`, for example `answers.factors.2` (the PWA's field paths).
    public static func path(_ location: [FieldIssue.PathComponent]) -> String {
        bodyLocation(location).map { component in
            switch component {
            case .key(let key): key
            case .index(let index): String(index)
            }
        }.joined(separator: ".")
    }

    /// Pydantic's "Value error, min must be <= max" → "Min must be <= max". Capitalised.
    public static func cleanMessage(_ message: String) -> String {
        var text = Substring(message)
        if let range = message.range(of: "Value error, ") {
            let rest = message[range.upperBound...]
            text = rest.prefix { $0 != "[" && $0 != "\n" }
            // JS `[^[\n]+` needs at least one character; otherwise the whole message stays.
            if text.isEmpty { text = Substring(message) }
        }
        let trimmed = JSNumber.trim(String(text))
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst()
    }

    private static let friendlyCodes: [ProblemCode: String] = [
        .conflict: "Conflict",
        .notFound: "Not found",
        .topicArchived: "This topic is archived",
        .invalidAnswers: "Some answers need attention",
        .incompatibleVersion: "This change is not allowed",
        .invalidRequest: "Some fields need attention",
    ]

    /// The banner over the form (`mapApiError(...).message`). A request-shape error with a single
    /// field issue shows that issue, since its detail is generic.
    public static func banner(for problem: Problem) -> String {
        if problem.code == .invalidRequest {
            guard problem.errors.count == 1, let only = problem.errors.first else {
                return "Some fields need attention"
            }
            let path = path(only.location)
            let message = cleanMessage(only.message)
            return path.isEmpty ? message : "\(path): \(message)"
        }
        let detail = cleanMessage(problem.detail)
        if !detail.isEmpty { return detail }
        return friendlyCodes[problem.code] ?? "Request failed"
    }

    /// Lands a rejected entry's server errors on the entry form's fields (fix mode).
    /// `["answers", key, …]` lands on that question, including one bad option of a multi-select
    /// (`["answers", "factors", 1]`); `captured_at`, `source` and `notes` on theirs. Everything
    /// else, and answers for keys the form doesn't have, is `unplaced`: show it in the banner.
    public static func entryForm(_ problem: Problem, questionKeys: Set<String>) -> EntryFormErrors {
        var result = EntryFormErrors(banner: banner(for: problem))
        for issue in problem.errors {
            let message = cleanMessage(issue.message)
            if let field = entryField(issue.location, questionKeys: questionKeys) {
                // A later issue replaces an earlier one on the same field, like react-hook-form's setError.
                result.fields[field] = message
            } else {
                result.unplaced.append(FieldIssue(location: bodyLocation(issue.location), message: message))
            }
        }
        return result
    }

    /// The entry form field a server `loc` belongs to, or nil.
    public static func entryField(_ location: [FieldIssue.PathComponent], questionKeys: Set<String>) -> EntryFormField?
    {
        let body = bodyLocation(location)
        guard case .key(let root)? = body.first else { return nil }
        switch root {
        case "answers":
            guard body.count > 1, case .key(let key) = body[1], questionKeys.contains(key) else { return nil }
            return .answer(key)
        case "captured_at": return .capturedAt
        case "source": return .source
        case "notes": return .notes
        default: return nil
        }
    }
}

/// A field of the entry form.
public enum EntryFormField: Sendable, Hashable {
    /// The question with this key.
    case answer(String)
    case capturedAt
    case source
    case notes
}

/// `ProblemMapping.entryForm`'s result.
public struct EntryFormErrors: Sendable, Hashable {
    public var banner: String
    public var fields: [EntryFormField: String]
    /// Issues no field shows, with body-relative locations; list them under the banner.
    public var unplaced: [FieldIssue]

    public init(banner: String, fields: [EntryFormField: String] = [:], unplaced: [FieldIssue] = []) {
        self.banner = banner
        self.fields = fields
        self.unplaced = unplaced
    }
}
