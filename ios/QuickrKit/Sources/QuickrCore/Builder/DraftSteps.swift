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
    /// Cues during the step (timers2.md §1.1).
    public var alerts: [DraftAlert]

    public init(id: UUID = UUID(), key: String, label: String, locked: Bool = false, alerts: [DraftAlert] = []) {
        self.id = id
        self.key = key
        self.label = label
        self.locked = locked
        self.alerts = alerts
    }

    /// A new, unpublished step (`newDraftStep`). `taken`: the other steps' keys (and the lap
    /// types', which share the namespace: ``TopicDraft/takenTimerKeys(step:history:)``); `history`: see
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

/// A field of one draft step or lap type.
public enum StepField: String, Sendable, Hashable {
    case key, label
}

extension TopicDraft {
    /// The timer fields of a draft.
    public struct TimerFields: Sendable, Hashable {
        public var timed: Bool
        public var steps: [DraftStep]
        public var laps: [DraftLapType]
        public var variables: [DraftVariable]
    }

    /// The draft a published timer opens as (`draftFromTimer`): timed when it has one; its steps,
    /// lap types and alerts locked so their keys never change; each variable's ms as its duration
    /// text. A v1 timer (`{steps}`) opens with no lap types, variables or alerts.
    public static func timerDraft(from timer: TopicTimer?) -> TimerFields {
        func alerts(_ list: [TopicTimer.Alert]) -> [DraftAlert] {
            list.map { DraftAlert(key: $0.key, label: $0.label, at: $0.at, locked: true) }
        }
        return TimerFields(
            timed: timer != nil,
            steps: (timer?.steps ?? []).map {
                DraftStep(key: $0.key, label: $0.label, locked: true, alerts: alerts($0.alerts))
            },
            laps: (timer?.laps ?? []).map {
                DraftLapType(key: $0.key, label: $0.label, locked: true, alerts: alerts($0.alerts))
            },
            variables: (timer?.variables ?? []).map {
                DraftVariable(name: $0.name, duration: DurationText.format($0.ms))
            })
    }

    // MARK: Steps

    public func stepIndex(of id: DraftStep.ID) -> Int? { steps.firstIndex { $0.id == id } }

    /// Whether another step fits (`max_steps`).
    public func canAddStep(limits: Limits = .serverDefaults) -> Bool { steps.count < limits.maxSteps }

    /// Appends a new, unnamed step and returns its id. Its key comes with its label.
    @discardableResult
    public mutating func addStep() -> DraftStep.ID {
        let step = DraftStep(key: "", label: "")
        steps.append(step)
        return step.id
    }

    /// Renames a step; a new step's key follows its label (`withStepLabel`), avoiding the lap
    /// types' keys too (one namespace).
    public mutating func setStepLabel(_ id: DraftStep.ID, _ label: String, history: TimerHistory = TimerHistory()) {
        guard let i = stepIndex(of: id) else { return }
        steps[i] = steps[i].withLabel(
            label, takenKeys: takenTimerKeys(step: i, history: history), history: history.steps)
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
    /// `max_steps`.
    public static func stepIssues(_ steps: [DraftStep], limits: Limits = .serverDefaults) -> [DraftIssue<DraftField>] {
        var issues: [DraftIssue<DraftField>] = []
        let keys = limits.keyMatcher
        if steps.count > limits.maxSteps {
            issues.append(.init(field: .steps, message: "At most \(limits.maxSteps) steps"))
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

    /// The timer's rules (`timerIssues`, timers2.md §1.3), in the server's order, at the draft's
    /// fields: the lists' sizes, the steps, the lap types (a key a step has is the server's
    /// "duplicate key (also a step)" at `laps.N.key`), the variables, each owner's alerts, then
    /// each expression with the server's message. The server reports the first; this reports
    /// them all.
    public func timerIssues(limits: Limits = .serverDefaults) -> [DraftIssue<DraftField>] {
        var issues: [DraftIssue<DraftField>] = []
        let keys = limits.keyMatcher
        let stepList = Self.stepIssues(steps, limits: limits)
        issues += stepList.filter { $0.field == .steps }
        if laps.count > limits.maxLapTypes {
            issues.append(.init(field: .laps, message: "At most \(limits.maxLapTypes) lap types"))
        }
        if variables.count > limits.maxVariables {
            issues.append(.init(field: .variables, message: "At most \(limits.maxVariables) variables"))
        }
        issues += stepList.filter { $0.field != .steps }

        let stepKeys = Set(steps.map { TextKey(BuilderText.strip($0.key)) }.filter { !$0.isEmpty })
        for (i, lap) in laps.enumerated() {
            let label = BuilderText.strip(lap.label)
            let key = BuilderText.strip(lap.key)
            if !label.isEmpty && key.isEmpty {
                issues.append(.init(field: .lap(i, .key), message: BuilderMessage.required))
            } else if !key.isEmpty && !keys.matches(key) {
                issues.append(.init(field: .lap(i, .key), message: BuilderMessage.key))
            } else if !key.isEmpty && stepKeys.contains(TextKey(key)) {
                issues.append(.init(field: .lap(i, .key), message: "A step has this key"))
            }
            if label.isEmpty { issues.append(.init(field: .lap(i, .label), message: BuilderMessage.required)) }
            let count = BuilderText.count(label)
            if count > limits.maxShortLabelLength {
                issues.append(
                    .init(field: .lap(i, .label), message: BuilderMessage.tooLong(limits.maxShortLabelLength, count)))
            }
        }
        for i in duplicates(laps.map { TextKey(BuilderText.strip($0.key)) })
        where !stepKeys.contains(TextKey(BuilderText.strip(laps[i].key))) {
            issues.append(.init(field: .lap(i, .key), message: "Another lap type has this key"))
        }

        for (i, variable) in variables.enumerated() {
            if case .failure(let e) = variable.validated(limits: limits) {
                issues += e.issues.map { .init(field: .variable(i, $0.field), message: $0.message) }
            }
        }
        for i in duplicates(variables.map { BuilderText.fold($0.name) }) {
            issues.append(.init(field: .variable(i, .name), message: "Another variable has this name"))
        }

        let owners: [(AlertOwner, [DraftAlert])] =
            steps.indices.map { (.step($0), steps[$0].alerts) } + laps.indices.map { (.lap($0), laps[$0].alerts) }
        for (owner, alerts) in owners {
            if alerts.count > limits.maxAlerts {
                issues.append(.init(field: .alerts(owner), message: "At most \(limits.maxAlerts) alerts"))
            }
            for (j, alert) in alerts.enumerated() {
                let label = BuilderText.strip(alert.label)
                let key = BuilderText.strip(alert.key)
                if label.isEmpty {
                    issues.append(.init(field: .alert(owner, j, .label), message: BuilderMessage.required))
                }
                let count = BuilderText.count(label)
                if count > limits.maxShortLabelLength {
                    issues.append(
                        .init(
                            field: .alert(owner, j, .label),
                            message: BuilderMessage.tooLong(limits.maxShortLabelLength, count)))
                }
                if !label.isEmpty && key.isEmpty {
                    issues.append(.init(field: .alert(owner, j, .key), message: BuilderMessage.required))
                } else if !key.isEmpty && !keys.matches(key) {
                    issues.append(.init(field: .alert(owner, j, .key), message: BuilderMessage.key))
                }
            }
            for j in duplicates(alerts.map { TextKey(BuilderText.strip($0.key)) }) {
                issues.append(.init(field: .alert(owner, j, .key), message: "Another alert here has this key"))
            }
        }

        let usable = DraftVariable.usable(variables, limits: limits)
        for (owner, alerts) in owners {
            for (j, alert) in alerts.enumerated() {
                if case .failure(let error) = Self.evaluate(alert.at, usable, limits: limits) {
                    issues.append(.init(field: .alert(owner, j, .at), message: Self.exprMessage(error)))
                }
            }
        }
        return issues
    }

    /// The `timer` the draft publishes (`timerFromDraft`): nil when not timed (its timer fields are
    /// then ignored), else the normalised v2 timer (timers2.md §1.4): every list present, keys and
    /// labels stripped, expressions as typed with `at_ms` evaluated, variable names lowercase.
    public func validatedTimer(limits: Limits = .serverDefaults) -> Result<TopicTimer?, DraftIssues<DraftField>> {
        guard timed else { return .success(nil) }
        let issues = timerIssues(limits: limits)
        if !issues.isEmpty { return .failure(DraftIssues(issues)) }
        let usable = DraftVariable.usable(variables, limits: limits)
        func alerts(_ list: [DraftAlert]) -> [TopicTimer.Alert] {
            list.map {
                let ms = try? Self.evaluate($0.at, usable, limits: limits).get()
                return .init(
                    key: BuilderText.strip($0.key), label: BuilderText.strip($0.label), at: $0.at, atMs: ms ?? 0)
            }
        }
        return .success(
            TopicTimer(
                steps: steps.map {
                    .init(key: BuilderText.strip($0.key), label: BuilderText.strip($0.label), alerts: alerts($0.alerts))
                },
                laps: laps.map {
                    .init(key: BuilderText.strip($0.key), label: BuilderText.strip($0.label), alerts: alerts($0.alerts))
                },
                variables: usable.map { .init(name: $0.name, ms: $0.ms) }))
    }
}

/// What changed in the timer between two versions, for the review sheet (`timerChanges`): the
/// compatibility report covers questions only. Steps, then lap types, variables and alerts
/// (timers2.md §1.6). Empty when nothing did.
public enum TimerChanges {
    public static func changes(base: TopicTimer?, next: TopicTimer?) -> [String] {
        guard let next else { return base == nil ? [] : ["No longer timed"] }
        var out: [String] = []
        if let base {
            out += list(base.steps.map { ($0.key, $0.label) }, next.steps.map { ($0.key, $0.label) }, "Step", "Steps")
        } else {
            let n = next.steps.count
            out.append(n == 0 ? "Timed, as a stopwatch (no steps)" : "Timed, with \(n) step\(n == 1 ? "" : "s")")
        }
        let was = base ?? TopicTimer(steps: [])
        out += list(was.laps.map { ($0.key, $0.label) }, next.laps.map { ($0.key, $0.label) }, "Lap type", "Lap types")
        out += variables(was.variables, next.variables)
        out += alerts(was, next)
        return out
    }

    /// Added / renamed / removed / reordered, by key.
    private static func list(
        _ before: [(key: String, label: String)], _ after: [(key: String, label: String)], _ noun: String,
        _ plural: String
    ) -> [String] {
        var out: [String] = []
        let old = Dictionary(before.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        let now = Set(after.map(\.key))
        for item in after {
            if let label = old[item.key] {
                if label != item.label { out.append("\(noun) renamed: \(label) → \(item.label)") }
            } else {
                out.append("\(noun) added: \(item.label)")
            }
        }
        for item in before where !now.contains(item.key) { out.append("\(noun) removed: \(item.label)") }
        let keptBefore = before.map(\.key).filter(now.contains)
        let keptAfter = after.map(\.key).filter { old[$0] != nil }
        if keptBefore != keptAfter { out.append("\(plural) reordered") }
        return out
    }

    private static func variables(_ before: [TopicTimer.Variable], _ after: [TopicTimer.Variable]) -> [String] {
        var out: [String] = []
        let old = Dictionary(before.map { ($0.name, $0.ms) }, uniquingKeysWith: { first, _ in first })
        let now = Set(after.map(\.name))
        for v in after {
            if let ms = old[v.name] {
                if ms != v.ms {
                    out.append(
                        "Variable changed: \(v.name), \(DurationText.format(ms)) → \(DurationText.format(v.ms))")
                }
            } else {
                out.append("Variable added: \(v.name) = \(DurationText.format(v.ms))")
            }
        }
        for v in before where !now.contains(v.name) { out.append("Variable removed: \(v.name)") }
        return out
    }

    /// Per owner in the new timer's order (steps, then lap types): added, renamed, changed, then
    /// removed alerts. A removed owner's alerts go with it; a new owner's are listed as added. An
    /// `at_ms` alone is no change (it follows `at` and the variables).
    private static func alerts(_ base: TopicTimer, _ next: TopicTimer) -> [String] {
        func owners(_ t: TopicTimer) -> [(id: String, label: String, alerts: [TopicTimer.Alert])] {
            t.steps.map { ("step:\($0.key)", $0.label, $0.alerts) }
                + t.laps.map { ("lap:\($0.key)", $0.label, $0.alerts) }
        }
        let old = Dictionary(owners(base).map { ($0.id, $0.alerts) }, uniquingKeysWith: { first, _ in first })
        var out: [String] = []
        for owner in owners(next) {
            let before = old[owner.id] ?? []
            let was = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Set(owner.alerts.map(\.key))
            let name = owner.label
            for alert in owner.alerts {
                guard let prior = was[alert.key] else {
                    out.append("Alert added: \(name) · \(alert.label) at \(alert.at)")
                    continue
                }
                if prior.label != alert.label { out.append("Alert renamed: \(name) · \(prior.label) → \(alert.label)") }
                if prior.at != alert.at {
                    out.append("Alert changed: \(name) · \(alert.label), \(prior.at) → \(alert.at)")
                }
            }
            for alert in before where !now.contains(alert.key) { out.append("Alert removed: \(name) · \(alert.label)") }
        }
        return out
    }
}
