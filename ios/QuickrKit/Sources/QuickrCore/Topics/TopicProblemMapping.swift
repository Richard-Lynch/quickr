/// A field of the topic settings' Details form.
public enum TopicDetailsField: String, Sendable, Hashable, CaseIterable {
    case name, slug, description
}

/// A rejected save, landed on a form: messages for its fields, and the banner for the rest (nil:
/// no banner, every issue has a field).
public struct TopicFormErrors<Field: Sendable & Hashable>: Sendable, Hashable {
    public var banner: String?
    public var fields: [Field: String]

    public init(banner: String? = nil, fields: [Field: String] = [:]) {
        self.banner = banner
        self.fields = fields
    }
}

/// Puts the server's errors back on the topic settings forms, as the PWA's `SettingsPage` does
/// (`MetaForm` and `ScheduleForm`'s error handling over `mapApiError` and `applyFieldErrors`). A
/// later issue for a field replaces an earlier one, like `setError`.
public enum TopicProblemMapping {
    /// The Details form (`PATCH` of name, slug, description). Issues that all land on a field
    /// show no banner. A 409 about the slug without a location (older servers) lands on the slug.
    public static func details(_ problem: Problem) -> TopicFormErrors<TopicDetailsField> {
        let message = ProblemMapping.banner(for: problem)
        var result = TopicFormErrors<TopicDetailsField>()
        var unplaced: [String] = []
        for issue in problem.errors {
            let text = ProblemMapping.cleanMessage(issue.message)
            if let field = TopicDetailsField(rawValue: ProblemMapping.path(issue.location)) {
                result.fields[field] = text
            } else {
                unplaced.append(text)
            }
        }
        if !problem.errors.isEmpty && unplaced.isEmpty { return result }
        if problem.code == .conflict && message.range(of: "slug", options: .caseInsensitive) != nil {
            result.fields[.slug] = message
        } else {
            result.banner = ([message] + unplaced).joined(separator: " — ")
        }
        return result
    }

    /// The Schedule form (`PATCH` of `schedule`). The banner shows when some issue has no field,
    /// or there are no field issues at all.
    public static func schedule(_ problem: Problem) -> TopicFormErrors<ScheduleField> {
        let message = ProblemMapping.banner(for: problem)
        var result = TopicFormErrors<ScheduleField>()
        var unplaced: [String] = []
        for issue in problem.errors {
            let text = ProblemMapping.cleanMessage(issue.message)
            if let field = ScheduleField(serverPath: ProblemMapping.path(issue.location)) {
                result.fields[field] = text
            } else {
                unplaced.append(text)
            }
        }
        if !unplaced.isEmpty || problem.errors.isEmpty {
            result.banner = ([message] + unplaced).joined(separator: " — ")
        }
        return result
    }
}
