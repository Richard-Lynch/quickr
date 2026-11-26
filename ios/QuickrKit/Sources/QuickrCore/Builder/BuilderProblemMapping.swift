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
        if parts.first == "timer" { return draft.timed ? timerField(Array(parts.dropFirst()), in: draft) : nil }
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

    /// A `timer.…` path (timers2.md §1.3) on the draft, which keeps the timer's lists at the top
    /// level (`timerFieldFor`): `timer.steps.N.key` → `.step(N, .key)`, `timer.laps.N.alerts.M.at`
    /// → `.alert(.lap(N), M, .at)`, `timer.variables.N.ms` → the variable's duration (the draft
    /// types one). An index the draft doesn't have lights up its list; another sub-field, the label
    /// (a variable's name); `at_ms`, the expression. Only called while timed (else the banner).
    private static func timerField(_ parts: [String], in draft: TopicDraft) -> DraftField {
        guard let list = parts.first else { return .steps }
        if list == "variables" {
            guard parts.count >= 2, let i = Int(parts[1]), draft.variables.indices.contains(i) else {
                return .variables
            }
            return .variable(i, parts.count >= 3 && parts[2] == "ms" ? .duration : .name)
        }
        guard list == "steps" || list == "laps" else { return .steps }
        let isLap = list == "laps"
        let whole: DraftField = isLap ? .laps : .steps
        guard parts.count >= 2, let i = Int(parts[1]) else { return whole }
        let alertCounts = isLap ? draft.laps.map(\.alerts.count) : draft.steps.map(\.alerts.count)
        guard alertCounts.indices.contains(i) else { return whole }
        let owner: AlertOwner = isLap ? .lap(i) : .step(i)
        let field = parts.count >= 3 ? parts[2] : ""
        if field == "key" { return isLap ? .lap(i, .key) : .step(i, .key) }
        guard field == "alerts" else { return isLap ? .lap(i, .label) : .step(i, .label) }
        guard parts.count >= 4, let j = Int(parts[3]), (0..<alertCounts[i]).contains(j) else { return .alerts(owner) }
        let sub = parts.count >= 5 ? parts[4] : ""
        let alertField: AlertField = sub == "key" ? .key : sub == "at" || sub == "at_ms" ? .at : .label
        return .alert(owner, j, alertField)
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
