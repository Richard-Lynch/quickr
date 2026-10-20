extension DraftQuestion {
    /// A best-effort question for the live preview (`previewQuestion`): a placeholder key and
    /// label fill in for missing ones, and invalid constraints are dropped instead of failing.
    /// `index` numbers the placeholders ("Question 3").
    public func preview(index: Int) -> Question {
        let limits = Limits.serverDefaults
        let keys = limits.keyMatcher
        var filled = self
        let key = BuilderText.strip(self.key)
        filled.key = keys.matches(key) ? key : "question_\(index + 1)"
        let label = BuilderText.strip(self.label)
        filled.label = label.isEmpty ? "Question \(index + 1)" : label

        let issues: DraftIssues<QuestionField>
        switch filled.validated(limits: limits, keys: keys) {
        case .success(let q): return q
        case .failure(let e): issues = e
        }
        let bad = Set(issues.issues.map(\.field.root))
        var relaxed = filled
        if bad.contains("help_text") { relaxed.helpText = "" }
        if bad.contains("unit") { relaxed.unit = "" }
        if bad.contains("min") || bad.contains("max") {
            relaxed.min = ""
            relaxed.max = ""
        }
        if bad.contains("decimals") { relaxed.decimals = "" }
        if bad.contains("min_length") || bad.contains("max_length") {
            relaxed.minLength = "0"
            relaxed.maxLength = String(Question.StringRules.defaultMaxLength)
        }
        relaxed.multiple = filled.multiple || filled.publishedMultiple
        if bad.contains("min_selected") || bad.contains("max_selected") {
            relaxed.minSelected = ""
            relaxed.maxSelected = ""
        }
        var values = Set<TextKey>()
        var labels = Set<TextKey>()
        relaxed.options = filled.options
            .filter { !BuilderText.strip($0.label).isEmpty }
            .enumerated()
            .map { i, o in
                var o = o
                if !keys.matches(o.value) { o.value = "option_\(i + 1)" }
                return o
            }
            .filter { values.insert(TextKey($0.value)).inserted }
            .filter { labels.insert(BuilderText.fold($0.label)).inserted }
        relaxed.publishedMultiple = false
        if relaxed.type == .enum && relaxed.options.allSatisfy(\.archived) { relaxed.options = [] }
        if case .success(let q) = relaxed.validated(limits: limits, keys: keys) { return q }
        // A choice with no usable options yet: show it with none.
        return Question(
            key: filled.key, label: filled.label, helpText: nil, required: filled.required,
            kind: .choice(.init(options: [], multiple: relaxed.multiple)))
    }
}
