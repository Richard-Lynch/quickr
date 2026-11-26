import Foundation

/// A lap type being edited (`DraftLapType` in `frontend/src/lib/builder.ts`, timers2.md §1.1):
/// laps cycle through the timer's lap types in order. Its key shares the steps' namespace.
public struct DraftLapType: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Derived from the label until the lap type is published; fixed from then on.
    public var key: String
    /// 1..64 characters (`ShortLabel`).
    public var label: String
    /// Exists in the base version: renaming keeps its key, so stats join across versions.
    public var locked: Bool
    public var alerts: [DraftAlert]

    public init(id: UUID = UUID(), key: String, label: String, locked: Bool = false, alerts: [DraftAlert] = []) {
        self.id = id
        self.key = key
        self.label = label
        self.locked = locked
        self.alerts = alerts
    }

    /// A new, unpublished lap type (`newDraftLapType`). `taken`: the draft's other lap types' and
    /// its steps' keys; `history`: see ``LapTypeKeys/key(for:taken:history:)``.
    public init(label: String, taken: some Sequence<String> = [String](), history: TimerHistory = TimerHistory()) {
        self.init(key: LapTypeKeys.key(for: label, taken: taken, history: history), label: label)
    }

    /// Renames the lap type (`withLapTypeLabel`): a published one keeps its key, a new one
    /// re-derives it.
    public func withLabel(_ label: String, takenKeys: some Sequence<String>, history: TimerHistory = TimerHistory())
        -> DraftLapType
    {
        var lap = self
        lap.label = label
        if !locked { lap.key = LapTypeKeys.key(for: label, taken: takenKeys, history: history) }
        return lap
    }
}

/// Every key the topic's versions have used, for steps and for lap types (one namespace,
/// timers2.md §1.1), each with the label of the latest version that has it (`TimerHistory`).
public struct TimerHistory: Sendable, Hashable {
    public var steps: [HistoricStep]
    public var laps: [HistoricStep]

    public init(steps: [HistoricStep] = [], laps: [HistoricStep] = []) {
        self.steps = steps
        self.laps = laps
    }

    /// From a topic's versions, in any order (`timerHistory`).
    public init(_ versions: [TopicVersion]) {
        self.init(steps: StepKeys.history(versions), laps: Self.lapHistory(versions))
    }

    /// This history with `newer`'s keys and labels on top: a key seen again takes the newer
    /// label; a new one is appended.
    public func then(_ newer: TimerHistory) -> TimerHistory {
        TimerHistory(steps: Self.merge(steps, newer.steps), laps: Self.merge(laps, newer.laps))
    }

    /// This history with a newer version's timer on top.
    public func then(_ timer: TopicTimer?) -> TimerHistory {
        then(
            TimerHistory(
                steps: (timer?.steps ?? []).map { HistoricStep(key: $0.key, label: $0.label) },
                laps: (timer?.laps ?? []).map { HistoricStep(key: $0.key, label: $0.label) }))
    }

    private static func lapHistory(_ versions: [TopicVersion]) -> [HistoricStep] {
        var order: [String] = []
        var labels: [String: String] = [:]
        for version in versions.sorted(by: { $0.version < $1.version }) {
            for lap in version.timer?.laps ?? [] {
                if labels[lap.key] == nil { order.append(lap.key) }
                labels[lap.key] = lap.label
            }
        }
        return order.map { HistoricStep(key: $0, label: labels[$0] ?? "") }
    }

    private static func merge(_ history: [HistoricStep], _ newer: [HistoricStep]) -> [HistoricStep] {
        var out = history
        for latest in newer {
            if let i = out.firstIndex(where: { $0.key == latest.key }) { out[i] = latest } else { out.append(latest) }
        }
        return out
    }
}

/// Lap-type keys (timers2.md §1.1, §1.6): stable once published, in the steps' namespace.
public enum LapTypeKeys {
    /// A new lap type's key from its label; "" for a blank label (`lapTypeKeyFor`). A label
    /// matching (ignoring case and surrounding space) a retired lap type whose key is free takes
    /// that key back; otherwise the key is derived (`lap` for a label with no usable characters)
    /// and avoids `taken` (the draft's other lap types and its steps), every historic lap-type key
    /// and every historic step key.
    public static func key(for label: String, taken: some Sequence<String>, history: TimerHistory) -> String {
        if BuilderText.strip(label).isEmpty { return "" }
        let used = Array(taken)
        let usedKeys = Set(used.map(TextKey.init))
        let folded = BuilderText.fold(label)
        if let same = history.laps.first(where: {
            !usedKeys.contains(TextKey($0.key)) && BuilderText.fold($0.label) == folded
        }) {
            return same.key
        }
        let derived = BuilderText.snakeKey(label)
        return BuilderText.uniqueKey(
            derived.isEmpty ? "lap" : derived, taken: used + history.laps.map(\.key) + history.steps.map(\.key))
    }
}

extension TopicDraft {
    public func lapTypeIndex(of id: DraftLapType.ID) -> Int? { laps.firstIndex { $0.id == id } }

    /// The keys a step (`.step`) or lap type at `index` must avoid beyond its own kind's history
    /// (`takenTimerKeys`): the draft's other steps and lap types, and for a step the historic
    /// lap-type keys (a lap type's key function adds the historic step keys itself).
    public func takenTimerKeys(step index: Int, history: TimerHistory) -> [String] {
        steps.indices.filter { $0 != index }.map { steps[$0].key } + laps.map(\.key) + history.laps.map(\.key)
    }

    public func takenTimerKeys(lapType index: Int) -> [String] {
        laps.indices.filter { $0 != index }.map { laps[$0].key } + steps.map(\.key)
    }

    /// Whether another lap type fits (`max_lap_types`).
    public func canAddLapType(limits: Limits = .serverDefaults) -> Bool { laps.count < limits.maxLapTypes }

    /// Appends a new, unnamed lap type and returns its id. Its key comes with its label.
    @discardableResult
    public mutating func addLapType() -> DraftLapType.ID {
        let lap = DraftLapType(key: "", label: "")
        laps.append(lap)
        return lap.id
    }

    /// Renames a lap type; a new one's key follows its label (`withLapTypeLabel`).
    public mutating func setLapTypeLabel(_ id: DraftLapType.ID, _ label: String, history: TimerHistory = TimerHistory())
    {
        guard let i = lapTypeIndex(of: id) else { return }
        laps[i] = laps[i].withLabel(label, takenKeys: takenTimerKeys(lapType: i), history: history)
    }

    /// Removes a lap type, published or not: past runs keep their own version's lap types.
    public mutating func removeLapType(_ id: DraftLapType.ID) {
        guard let i = lapTypeIndex(of: id) else { return }
        laps.remove(at: i)
    }

    /// Moves a lap type to `destination` (its index once moved): laps cycle in this order.
    public mutating func moveLapType(_ id: DraftLapType.ID, to destination: Int) {
        guard let i = lapTypeIndex(of: id) else { return }
        laps.insert(laps.remove(at: i), at: Swift.max(0, Swift.min(destination, laps.count)))
    }
}
