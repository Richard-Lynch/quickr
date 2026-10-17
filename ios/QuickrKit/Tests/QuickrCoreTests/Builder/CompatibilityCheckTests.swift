import QuickrCore
import Testing

private func i(_ key: String, label: String? = nil, required: Bool = true, min: Int? = nil, max: Int? = nil) -> Question
{
    Question(key: key, label: label ?? key.capitalized, required: required, kind: .int(.init(min: min, max: max)))
}

private func d(
    _ key: String, min: Double? = nil, max: Double? = nil, decimals: Int? = nil, unit: String? = nil
) -> Question {
    Question(key: key, label: key.capitalized, kind: .double(.init(min: min, max: max, decimals: decimals, unit: unit)))
}

private func s(_ key: String, required: Bool = true, minLength: Int = 0, maxLength: Int = 500, multiline: Bool = false)
    -> Question
{
    Question(
        key: key, label: key.capitalized, required: required,
        kind: .string(.init(minLength: minLength, maxLength: maxLength, multiline: multiline)))
}

private func e(
    _ key: String, _ values: String..., archived: Set<String> = [], multiple: Bool = false, minSelected: Int? = nil,
    maxSelected: Int? = nil
) -> Question {
    Question(
        key: key, label: key.capitalized,
        kind: .choice(
            .init(
                options: values.map { EnumOption(value: $0, label: $0.capitalized, archived: archived.contains($0)) },
                multiple: multiple, minSelected: minSelected, maxSelected: maxSelected)))
}

private func check(_ history: [[Question]], _ proposed: [Question]) -> CompatibilityReport {
    CompatibilityCheck.report(history: history, proposed: proposed)
}

private func levels(_ r: CompatibilityReport, _ level: CompatibilityReport.Level) -> [String?: String] {
    Dictionary(r.issues.filter { $0.level == level }.map { ($0.questionKey, $0.message) }, uniquingKeysWith: { $1 })
}

private func kinds(_ r: CompatibilityReport) -> [String: CompatibilityReport.ChangeKind] {
    Dictionary(r.changes.map { ($0.questionKey, $0.kind) }, uniquingKeysWith: { $1 })
}

/// backend/tests/test_compat.py, case for case (the vectors cover the same ground against the
/// real server output).
@Suite struct CompatibilityCheckTests {
    @Test func noChangesIsAnError() {
        let r = check([[i("a"), s("b")]], [i("a"), s("b")])
        #expect(!r.ok)
        #expect(levels(r, .error) == [nil: "no changes to publish"])
        #expect(r.changes.isEmpty)
    }

    @Test func nextVersion() {
        let v1 = [i("a")]
        let v2 = [i("a"), s("b")]
        #expect(check([v1], v2).nextVersion == 2)
        #expect(check([v1, v2], [s("b")]).nextVersion == 3)
    }

    @Test func addQuestion() {
        let r = check([[i("a")]], [i("a"), s("b"), s("c", required: false)])
        #expect(r.ok)
        #expect(kinds(r) == ["b": .added, "c": .added])
        // Only the required addition gets the info note.
        #expect(Set(levels(r, .info).keys) == ["b"])
    }

    @Test func removeQuestionWarns() {
        let r = check([[i("a"), s("b")]], [i("a")])
        #expect(r.ok)
        #expect(kinds(r) == ["b": .removed])
        #expect(levels(r, .warning)["b"]?.contains("historic answers are kept") == true)
    }

    @Test func typeChangeIsError() {
        let r = check([[i("a")]], [d("a")])
        #expect(!r.ok)
        #expect(levels(r, .error)["a"] == "type cannot change (int -> double); use a new key")
        #expect(kinds(r)["a"] == nil)
    }

    @Test func typeChangeDetectedAcrossHistory() {
        // A key removed in v2 and re-added in v3 with another type is still blocked.
        let r = check([[i("a"), s("b")], [s("b")]], [s("b"), s("a")])
        #expect(!r.ok)
        #expect(levels(r, .error)["a"]?.contains("type cannot change (int -> str)") == true)
    }

    @Test func restoreRemovedQuestion() {
        let r = check([[i("a", max: 10), s("b")], [s("b")]], [s("b"), i("a", label: "New label", max: 10)])
        #expect(r.ok)
        let change = r.changes.first { $0.questionKey == "a" }
        #expect(change?.kind == .restored)
        #expect(change?.details == ["label: A -> New label"])
    }

    @Test func restoreComparesAgainstLatestPriorDefinition() {
        let r = check([[i("a", max: 5), s("b")], [i("a", max: 50), s("b")], [s("b")]], [s("b"), i("a", max: 50)])
        #expect(r.ok)
        #expect(r.changes.first { $0.questionKey == "a" }?.details == [])
    }

    @Test func restoredEnumCannotDropOptions() {
        let r = check([[e("m", "x", "y"), s("b")], [s("b")]], [s("b"), e("m", "x")])
        #expect(!r.ok)
        #expect(levels(r, .error)["m"] == "option 'y' cannot be removed; archive it instead")
    }

    @Test func enumOptionRemovalIsError() {
        let r = check([[e("m", "x", "y", "z")]], [e("m", "x")])
        #expect(!r.ok)
        #expect(
            r.issues.filter { $0.level == .error }.map(\.message).sorted() == [
                "option 'y' cannot be removed; archive it instead",
                "option 'z' cannot be removed; archive it instead",
            ])
    }

    @Test func enumArchiveAddRelabelReorder() {
        let proposed = Question(
            key: "m", label: "M",
            kind: .choice(
                .init(options: [
                    EnumOption(value: "y", label: "Why"), EnumOption(value: "x", label: "X", archived: true),
                    EnumOption(value: "z", label: "Z"),
                ])))
        let r = check([[e("m", "x", "y")]], [proposed])
        #expect(r.ok)
        #expect(r.changes.count == 1)
        #expect(r.changes.first?.kind == .modified)
        #expect(
            Set(r.changes.first?.details ?? []) == [
                "option added: z", "option y label: Y -> Why", "option x archived", "options reordered",
            ])
    }

    @Test func enumUnarchive() {
        let r = check([[e("m", "x", "y", archived: ["y"])]], [e("m", "x", "y")])
        #expect(r.ok)
        #expect(r.changes.first?.details == ["option y unarchived"])
    }

    @Test func questionReorder() {
        let r = check([[i("a"), i("b"), i("c")]], [i("c"), i("a"), i("b")])
        #expect(r.ok)
        #expect(r.changes.map { "\($0.kind.rawValue) \($0.questionKey)" } == ["reordered *"])
    }

    @Test func reorderIgnoresAddedAndRemoved() {
        let r = check([[i("a"), i("b"), i("c")]], [i("new"), i("a"), i("c")])
        #expect(kinds(r)["*"] == nil)
    }

    @Test func tightenedNumericRangeWarns() {
        let r = check([[i("a", min: 0, max: 10), d("b")]], [i("a", min: 1, max: 10), d("b", max: 3.5)])
        #expect(r.ok)
        let warnings = levels(r, .warning)
        #expect(Set(warnings.keys) == ["a", "b"])
        #expect(warnings["a"]?.contains("range tightened") == true)
        let details = Dictionary(r.changes.map { ($0.questionKey, $0.details) }, uniquingKeysWith: { $1 })
        #expect(details["a"] == ["min: 0 -> 1"])
        #expect(details["b"] == ["max: none -> 3.5"])
    }

    @Test func loosenedRangeDoesNotWarn() {
        let r = check([[i("a", min: 0, max: 10)]], [i("a", min: -5)])
        #expect(r.ok)
        #expect(levels(r, .warning).isEmpty)
        #expect(r.changes.first?.details == ["min: 0 -> -5", "max: 10 -> none"])
    }

    @Test func doubleSpecificAttrs() {
        let r = check([[d("a", decimals: 1, unit: "kg")]], [d("a", decimals: 2, unit: "lb")])
        #expect(r.changes.first?.details == ["unit: kg -> lb", "decimals: 1 -> 2"])
    }

    @Test func doublesPrintAsTheServerPrintsThem() {
        let r = check([[d("a", min: 7, max: 1e-5)]], [d("a", min: 0.5, max: 1e20)])
        #expect(r.changes.first?.details == ["min: 7 -> 0.5", "max: 1e-05 -> 1e+20"])
    }

    @Test func strLengthTightenedWarns() {
        let r = check([[s("a", maxLength: 100)]], [s("a", maxLength: 50, multiline: true)])
        #expect(r.ok)
        #expect(levels(r, .warning)["a"]?.contains("length limits tightened") == true)
        #expect(r.changes.first?.details == ["max_length: 100 -> 50", "multiline: False -> True"])
    }

    @Test func nowRequiredWarns() {
        let r = check([[i("a", required: false)]], [i("a")])
        #expect(r.ok)
        #expect(levels(r, .warning)["a"]?.contains("now required") == true)
        #expect(r.changes.first?.details == ["required: False -> True"])
    }

    @Test func labelAndHelpChanges() {
        var help = i("a", label: "Alpha")
        help.helpText = "Some help"
        let r = check([[i("a")]], [help])
        #expect(r.changes.first?.details == ["label: A -> Alpha", "help_text: none -> Some help"])
        #expect(r.issues.isEmpty)
    }

    @Test func singleToMultipleIsAWarning() {
        let r = check([[e("f", "a", "b")]], [e("f", "a", "b", multiple: true, maxSelected: 2)])
        #expect(r.ok)
        #expect(
            levels(r, .warning) == ["f": "now multi-select; historic single answers count as one-option selections"])
        #expect(r.changes.first?.details == ["multiple: False -> True", "max_selected: none -> 2"])
    }

    @Test func multipleToSingleIsAnError() {
        let r = check([[e("f", "a", "b", multiple: true)]], [e("f", "a", "b")])
        #expect(!r.ok)
        #expect(levels(r, .error) == ["f": "a multi-select question cannot become single-select; use a new key"])
    }

    @Test func multipleToSingleBlockedForRestoredKeys() {
        let r = check([[e("f", "a", multiple: true), i("x")], [i("x")]], [i("x"), e("f", "a")])
        #expect(!r.ok)
        #expect(levels(r, .error)["f"] != nil)
    }

    @Test func selectionLimitsTightenedWarns() {
        let v1 = [e("f", "a", "b", "c", multiple: true, maxSelected: 3)]
        let r = check([v1], [e("f", "a", "b", "c", multiple: true, minSelected: 1, maxSelected: 2)])
        #expect(r.ok)
        #expect(
            levels(r, .warning) == ["f": "selection limits tightened; historic answers remain valid for their version"])
        let loosened = check([v1], [e("f", "a", "b", "c", multiple: true)])
        #expect(loosened.ok)
        #expect(levels(loosened, .warning).isEmpty)
    }

    @Test func blockingIssuesLightUpTheirQuestionKeys() {
        let r = check([[i("a"), e("f", "x", "y")]], [i("a"), e("f", "x")])
        var draft = TopicDraft.editing(name: "T", slug: "t", description: "", questions: [i("a"), e("f", "x", "y")])
        draft.questions[1].options.removeLast()
        #expect(
            BuilderProblemMapping.blockingFields(r, draft: draft) == [
                .question(1, .key): "option 'y' cannot be removed; archive it instead"
            ])
    }
}
