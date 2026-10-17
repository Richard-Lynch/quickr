/// Puts the server's errors back on the builder (`frontend/src/components/builder/serverErrors.ts`
/// and `EditQuestionsPage`).
public enum BuilderProblemMapping {
    /// The builder field for a server error path relative to the body (`ProblemMapping.path`),
    /// or nil: show it in the banner (`builderFieldFor`). Unknown parts of a question light up its
    /// key so the card opens. Schedule paths are nil here; the schedule editor (TOPIC) maps them.
    public static func field(for path: String, in draft: TopicDraft) -> DraftField? {
        switch path {
        case "name": return .name
        case "slug": return .slug
        case "description": return .description
        case "change_note": return .changeNote
        case "questions": return .questions
        default: break
        }
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "questions", let i = Int(parts[1]) else { return nil }
        guard draft.questions.indices.contains(i) else { return .questions }
        let rest = Array(parts.dropFirst(2))
        if rest.count == 3, rest[0] == "options", let j = Int(rest[1]), draft.questions[i].options.indices.contains(j) {
            if rest[2] == "value" { return .question(i, .optionValue(j)) }
            if rest[2] == "label" { return .question(i, .optionLabel(j)) }
        }
        if rest.count == 1, let field = fields[rest[0]] { return .question(i, field) }
        return .question(i, .key)
    }

    private static let fields: [String: QuestionField] = [
        "key": .key, "label": .label, "help_text": .helpText, "min": .min, "max": .max, "unit": .unit,
        "decimals": .decimals, "min_length": .minLength, "max_length": .maxLength, "options": .options,
        "multiple": .multiple, "min_selected": .minSelected, "max_selected": .maxSelected,
    ]

    /// Lands a rejected create, check or publish on the builder's fields. Issues no field shows
    /// stay `unplaced` (body-relative locations) for the banner.
    public static func builderForm(_ problem: Problem, draft: TopicDraft) -> BuilderFormErrors {
        var result = BuilderFormErrors(banner: ProblemMapping.banner(for: problem))
        for issue in problem.errors {
            let message = ProblemMapping.cleanMessage(issue.message)
            if let field = field(for: ProblemMapping.path(issue.location), in: draft) {
                // A later issue replaces an earlier one on the same field, like react-hook-form's setError.
                result.fields[field] = message
            } else {
                result.unplaced.append(
                    FieldIssue(location: ProblemMapping.bodyLocation(issue.location), message: message))
            }
        }
        return result
    }

    /// A compatibility report's blocking issues on the key of the question they name (the PWA
    /// lights them up before showing the report).
    public static func blockingFields(_ report: CompatibilityReport, draft: TopicDraft) -> [DraftField: String] {
        var out: [DraftField: String] = [:]
        for issue in report.issues where issue.level == .error {
            guard let key = issue.questionKey,
                let i = draft.questions.firstIndex(where: { TextKey(BuilderText.strip($0.key)) == TextKey(key) })
            else { continue }
            out[.question(i, .key)] = issue.message
        }
        return out
    }
}

/// `BuilderProblemMapping.builderForm`'s result.
public struct BuilderFormErrors: Sendable, Hashable {
    public var banner: String
    public var fields: [DraftField: String]
    /// Issues no field shows, with body-relative locations; list them under the banner.
    public var unplaced: [FieldIssue]

    public init(banner: String, fields: [DraftField: String] = [:], unplaced: [FieldIssue] = []) {
        self.banner = banner
        self.fields = fields
        self.unplaced = unplaced
    }
}
