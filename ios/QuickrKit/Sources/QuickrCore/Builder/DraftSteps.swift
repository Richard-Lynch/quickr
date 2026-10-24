import Foundation

/// One named step of a timed topic being edited (`DraftStep` in `frontend/src/lib/builder.ts`,
/// timers.md §2.1).
public struct DraftStep: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Derived from the label until the step is published; fixed from then on.
    public var key: String
    public var label: String
    /// Exists in the base version: renaming keeps its key, so stats join across versions.
    public var locked: Bool

    public init(id: UUID = UUID(), key: String, label: String, locked: Bool = false) {
        self.id = id
        self.key = key
        self.label = label
        self.locked = locked
    }

    /// A new, unpublished step (`newDraftStep`). `taken`: the other steps' keys; `history`: see
    /// ``StepKeys/key(for:taken:history:)``.
    public init(label: String, taken: some Sequence<String> = [String](), history: [HistoricStep] = []) {
        self.init(key: StepKeys.key(for: label, taken: taken, history: history), label: label)
    }

    /// Renames the step (`withStepLabel`). A published step keeps its key; a new one re-derives
    /// it from the label.
    public func withLabel(_ label: String, takenKeys: some Sequence<String>, history: [HistoricStep] = [])
        -> DraftStep
    {
        var step = self
        step.label = label
        if !locked { step.key = StepKeys.key(for: label, taken: takenKeys, history: history) }
        return step
    }
}

/// A step key some version of the topic has used, with its latest label (`HistoricStep`).
public struct HistoricStep: Sendable, Hashable {
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// Step keys (timers.md §2.1): stable once published, so stats join on them across versions.
public enum StepKeys {
    /// Steps per version (backend `MAX_STEPS`, timers.md §5); `GET /limits` doesn't carry it.
    public static let maxSteps = 30

    /// Every step key any version has used, with the label of the latest version that has it
    /// (`stepHistory`; versions in any order).
    public static func history(_ versions: [TopicVersion]) -> [HistoricStep] {
        var order: [String] = []
        var labels: [String: String] = [:]
        for version in versions.sorted(by: { $0.version < $1.version }) {
            for step in version.timer?.steps ?? [] {
                if labels[step.key] == nil { order.append(step.key) }
                labels[step.key] = step.label
            }
        }
        return order.map { HistoricStep(key: $0, label: labels[$0] ?? "") }
    }

    /// A new step's key from its label; "" for a blank label (`stepKeyFor`). `taken`: the other
    /// draft steps' keys. A label matching (ignoring case and surrounding space) a historic step
    /// whose key is free is that step again, and takes its key back; otherwise the key is derived
    /// from the label and unique among `taken` and every historic key (`prep`, else `prep_2`…).
    public static func key(for label: String, taken: some Sequence<String>, history: [HistoricStep]) -> String {
        if BuilderText.strip(label).isEmpty { return "" }
        let used = Array(taken)
        let usedKeys = Set(used.map(TextKey.init))
        let folded = BuilderText.fold(label)
        if let same = history.first(where: {
            !usedKeys.contains(TextKey($0.key)) && BuilderText.fold($0.label) == folded
        }) {
            return same.key
        }
        let derived = BuilderText.snakeKey(label)
        return BuilderText.uniqueKey(derived.isEmpty ? "step" : derived, taken: used + history.map(\.key))
    }
}

/// A field of one draft step.
public enum StepField: String, Sendable, Hashable {
    case key, label
}

extension TopicDraft {
    /// The draft a published timer opens as (`draftFromTimer`): timed when it has one, its steps
    /// locked so their keys never change.
    public static func steps(from timer: TopicTimer?) -> (timed: Bool, steps: [DraftStep]) {
        (timer != nil, (timer?.steps ?? []).map { DraftStep(key: $0.key, label: $0.label, locked: true) })
    }

    // MARK: Steps

    public func stepIndex(of id: DraftStep.ID) -> Int? { steps.firstIndex { $0.id == id } }

    /// Whether another step fits (``StepKeys/maxSteps``).
    public var canAddStep: Bool { steps.count < StepKeys.maxSteps }

    /// Appends a new, unnamed step and returns its id. Its key comes with its label.
    @discardableResult
    public mutating func addStep() -> DraftStep.ID {
        let step = DraftStep(key: "", label: "")
        steps.append(step)
        return step.id
    }

    /// Renames a step; a new step's key follows its label (`withStepLabel`).
    public mutating func setStepLabel(_ id: DraftStep.ID, _ label: String, history: [HistoricStep] = []) {
        guard let i = stepIndex(of: id) else { return }
        let taken = steps.indices.filter { $0 != i }.map { steps[$0].key }
        steps[i] = steps[i].withLabel(label, takenKeys: taken, history: history)
    }

    /// Removes a step, published or not: past runs keep their own steps (timers.md §2.1).
    public mutating func removeStep(_ id: DraftStep.ID) {
        guard let i = stepIndex(of: id) else { return }
        steps.remove(at: i)
    }

    /// Moves a step to `destination` (its index once moved), like the PWA's up and down.
    public mutating func moveStep(_ id: DraftStep.ID, to destination: Int) {
        guard let i = stepIndex(of: id) else { return }
        steps.insert(steps.remove(at: i), at: Swift.max(0, Swift.min(destination, steps.count)))
    }

    // MARK: Validation

    /// The steps' rules (`stepIssues`, timers.md §2.1, §5): a label (at most the label limit), a
    /// key matching the key pattern, keys unique (labels may repeat, as on the server), at most
    /// ``StepKeys/maxSteps``.
    public static func stepIssues(_ steps: [DraftStep], limits: Limits = .serverDefaults) -> [DraftIssue<DraftField>] {
        var issues: [DraftIssue<DraftField>] = []
        let keys = limits.keyMatcher
        if steps.count > StepKeys.maxSteps {
            issues.append(.init(field: .steps, message: "At most \(StepKeys.maxSteps) steps"))
        }
        for (i, step) in steps.enumerated() {
            let label = BuilderText.strip(step.label)
            if label.isEmpty { issues.append(.init(field: .step(i, .label), message: BuilderMessage.required)) }
            let count = BuilderText.count(label)
            if count > limits.maxLabelLength {
                issues.append(
                    .init(field: .step(i, .label), message: BuilderMessage.tooLong(limits.maxLabelLength, count)))
            }
            let key = BuilderText.strip(step.key)
            if !label.isEmpty && key.isEmpty {
                issues.append(.init(field: .step(i, .key), message: BuilderMessage.required))
            } else if !key.isEmpty && !keys.matches(key) {
                issues.append(.init(field: .step(i, .key), message: BuilderMessage.key))
            }
        }
        for i in duplicates(steps.map { TextKey(BuilderText.strip($0.key)) }) {
            issues.append(.init(field: .step(i, .key), message: "Another step has this key"))
        }
        return issues
    }

    /// The `timer` the draft publishes (`timerFromDraft`): nil when not timed (its steps are then
    /// ignored), else its steps stripped, in order.
    public func validatedTimer(limits: Limits = .serverDefaults) -> Result<TopicTimer?, DraftIssues<DraftField>> {
        guard timed else { return .success(nil) }
        let issues = Self.stepIssues(steps, limits: limits)
        if !issues.isEmpty { return .failure(DraftIssues(issues)) }
        return .success(
            TopicTimer(
                steps: steps.map { .init(key: BuilderText.strip($0.key), label: BuilderText.strip($0.label)) }))
    }
}

/// What changed in the timer between two versions, for the review sheet (`timerChanges`): the
/// compatibility report covers questions only. Empty when nothing did.
public enum TimerChanges {
    public static func changes(base: TopicTimer?, next: TopicTimer?) -> [String] {
        switch (base, next) {
        case (nil, nil): return []
        case (nil, let next?):
            let n = next.steps.count
            return [n == 0 ? "Timed, as a stopwatch (no steps)" : "Timed, with \(n) step\(n == 1 ? "" : "s")"]
        case (_?, nil): return ["No longer timed"]
        case (let base?, let next?):
            var out: [String] = []
            let before = Dictionary(base.steps.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let after = Set(next.steps.map(\.key))
            for step in next.steps {
                if let old = before[step.key] {
                    if old.label != step.label { out.append("Step renamed: \(old.label) → \(step.label)") }
                } else {
                    out.append("Step added: \(step.label)")
                }
            }
            for step in base.steps where !after.contains(step.key) { out.append("Step removed: \(step.label)") }
            let keptBefore = base.steps.map(\.key).filter(after.contains)
            let keptAfter = next.steps.map(\.key).filter { before[$0] != nil }
            if keptBefore != keptAfter { out.append("Steps reordered") }
            return out
        }
    }
}
