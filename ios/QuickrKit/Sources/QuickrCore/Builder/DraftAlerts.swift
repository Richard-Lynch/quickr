import Foundation

/// An alert being edited on a step or lap type (`DraftAlert` in `frontend/src/lib/builder.ts`,
/// timers2.md §1.1): a cue when the segment's active time reaches `at`, an expression (§2).
public struct DraftAlert: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Derived from the label (unique within its owner) until published; fixed from then on.
    public var key: String
    public var label: String
    /// The expression as typed: never trimmed, so an error's position is an offset into it.
    public var at: String
    /// Exists in the base version: renaming keeps its key.
    public var locked: Bool

    public init(id: UUID = UUID(), key: String, label: String, at: String, locked: Bool = false) {
        self.id = id
        self.key = key
        self.label = label
        self.at = at
        self.locked = locked
    }

    /// A new, unpublished alert (`newDraftAlert`). `taken`: its owner's other alerts' keys.
    public init(label: String, taken: some Sequence<String> = [String](), at: String = "") {
        self.init(key: AlertKeys.key(for: label, taken: taken), label: label, at: at)
    }

    /// Renames the alert (`withAlertLabel`): a published one keeps its key, a new one re-derives it.
    public func withLabel(_ label: String, takenKeys: some Sequence<String>) -> DraftAlert {
        var alert = self
        alert.label = label
        if !locked { alert.key = AlertKeys.key(for: label, taken: takenKeys) }
        return alert
    }
}

/// Alert keys (timers2.md §1.1): unique within their step or lap type.
public enum AlertKeys {
    /// An alert's key from its label (`alertKeyFor`): unique among `taken`, `alert` for a label
    /// with no usable characters, "" for a blank one.
    public static func key(for label: String, taken: some Sequence<String>) -> String {
        if BuilderText.strip(label).isEmpty { return "" }
        let derived = BuilderText.snakeKey(label)
        return BuilderText.uniqueKey(derived.isEmpty ? "alert" : derived, taken: taken)
    }
}

/// A step or a lap type of the draft, by id: the owner of alerts.
public enum TimerItemID: Sendable, Hashable {
    case step(DraftStep.ID)
    case lapType(DraftLapType.ID)
}

/// An alert expression's live evaluation in the editor (`alertPreview`, timers2.md §1.6): the
/// whole ms and `fmtDuration` of it, or the server's 422 message (as the builder shows it) and
/// the code-point offset it is reported at.
public enum AlertPreview: Sendable, Hashable {
    case value(ms: Int, text: String)
    case error(message: String, pos: Int)
}

extension TopicDraft {
    /// Evaluates `at` over `variables` (the valid ones, the first of a repeated name), as the
    /// server will (`alertPreview`). The expression's length limit is the evaluator's (64, the
    /// server's `MAX_EXPR_LENGTH`).
    public static func alertPreview(
        _ at: String, variables: [DraftVariable], limits: Limits = .serverDefaults
    ) -> AlertPreview {
        switch evaluate(at, DraftVariable.usable(variables, limits: limits)) {
        case .success(let ms): .value(ms: ms, text: DurationFormat.format(ms))
        case .failure(let error): .error(message: exprMessage(error), pos: error.pos)
        }
    }

    static func evaluate(_ at: String, _ variables: [(name: String, ms: Int)]) -> Result<Int, TimerExpr.ExprError> {
        let table = Dictionary(variables.map { ($0.name, $0.ms) }, uniquingKeysWith: { first, _ in first })
        do {
            return .success(try TimerExpr.evaluate(at, variables: table))
        } catch {
            return .failure(error)
        }
    }

    /// The text an expression error shows: the server's 422 message as the builder shows any
    /// server message (`cleanMessage`), so a field reads the same before and after submitting.
    static func exprMessage(_ error: TimerExpr.ExprError) -> String {
        ProblemMapping.cleanMessage(error.description)
    }

    // MARK: Alerts

    /// The alerts of a step or lap type ([] for an unknown one).
    public func alerts(of item: TimerItemID) -> [DraftAlert] {
        switch item {
        case .step(let id): stepIndex(of: id).map { steps[$0].alerts } ?? []
        case .lapType(let id): lapTypeIndex(of: id).map { laps[$0].alerts } ?? []
        }
    }

    /// The count badge of a collapsed step or lap type row.
    public func alertCount(_ item: TimerItemID) -> Int { alerts(of: item).count }

    /// Appends a new, unnamed alert to a step or lap type and returns its id; nil for an unknown
    /// owner. Its key comes with its label.
    @discardableResult
    public mutating func addAlert(to item: TimerItemID) -> DraftAlert.ID? {
        let alert = DraftAlert(key: "", label: "", at: "")
        guard editAlerts(item, { $0.append(alert) }) else { return nil }
        return alert.id
    }

    /// Renames an alert; a new one's key follows its label, unique within its owner.
    public mutating func setAlertLabel(_ item: TimerItemID, _ id: DraftAlert.ID, _ label: String) {
        editAlerts(item) { alerts in
            guard let j = alerts.firstIndex(where: { $0.id == id }) else { return }
            let taken = alerts.indices.filter { $0 != j }.map { alerts[$0].key }
            alerts[j] = alerts[j].withLabel(label, takenKeys: taken)
        }
    }

    /// Sets an alert's expression, as typed.
    public mutating func setAlertAt(_ item: TimerItemID, _ id: DraftAlert.ID, _ at: String) {
        editAlerts(item) { alerts in
            guard let j = alerts.firstIndex(where: { $0.id == id }) else { return }
            alerts[j].at = at
        }
    }

    /// Removes an alert, published or not (past runs keep their own version's alerts).
    public mutating func removeAlert(_ item: TimerItemID, _ id: DraftAlert.ID) {
        editAlerts(item) { $0.removeAll { $0.id == id } }
    }

    /// Moves an alert to `destination` (its index once moved) within its owner.
    public mutating func moveAlert(_ item: TimerItemID, _ id: DraftAlert.ID, to destination: Int) {
        editAlerts(item) { alerts in
            guard let j = alerts.firstIndex(where: { $0.id == id }) else { return }
            alerts.insert(alerts.remove(at: j), at: Swift.max(0, Swift.min(destination, alerts.count)))
        }
    }

    @discardableResult
    private mutating func editAlerts(_ item: TimerItemID, _ edit: (inout [DraftAlert]) -> Void) -> Bool {
        switch item {
        case .step(let id):
            guard let i = stepIndex(of: id) else { return false }
            edit(&steps[i].alerts)
        case .lapType(let id):
            guard let i = lapTypeIndex(of: id) else { return false }
            edit(&laps[i].alerts)
        }
        return true
    }
}
