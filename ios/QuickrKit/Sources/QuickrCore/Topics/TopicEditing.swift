import Foundation

/// What a Details save changes (the PWA's `MetaForm` sends only the fields that differ).
public struct TopicDetailsChange: Sendable, Hashable {
    public var name: String?
    public var slug: String?
    public var description: String?

    public init(name: String? = nil, slug: String? = nil, description: String? = nil) {
        self.name = name
        self.slug = slug
        self.description = description
    }

    /// The fields of `details` that differ from `topic`'s; nil when none do ("Nothing to save").
    public init?(_ details: TopicDraft.Details, from topic: Topic) {
        self.init(
            name: details.name == topic.name ? nil : details.name,
            slug: details.slug == topic.slug ? nil : details.slug,
            description: details.description == topic.description ? nil : details.description)
        if name == nil && slug == nil && description == nil { return nil }
    }
}

// MARK: - The schedule editor's controls (`ScheduleEditor.tsx`)

extension ScheduleDraft {
    /// The weekday shortcuts under the day buttons.
    public struct DayPreset: Sendable, Hashable, Identifiable {
        public var label: String
        public var days: [Int]
        public var id: String { label }
    }

    public static let dayPresets = [
        DayPreset(label: "Every day", days: allDays),
        DayPreset(label: "Weekdays", days: [1, 2, 3, 4, 5]),
        DayPreset(label: "Weekends", days: [6, 7]),
    ]

    /// Whether `preset` is the current selection (its button shows pressed).
    public func isSelected(_ preset: DayPreset) -> Bool { preset.days == days.sorted() }

    /// A day button: on if off, off if on; the list stays sorted.
    public mutating func toggleDay(_ day: Int) {
        days = (days.contains(day) ? days.filter { $0 != day } : days + [day]).sorted()
    }

    /// "+ Time" shows while there is room for another.
    public func canAddTime(limits: Limits) -> Bool { times.count < limits.scheduleMaxTimes }

    /// Adds the next sensible time (``nextTime(after:)``) if there is room.
    public mutating func addTime(limits: Limits) {
        guard canAddTime(limits: limits) else { return }
        times.append(Self.nextTime(after: times))
    }

    /// A time's remove button shows while there is more than one.
    public var canRemoveTime: Bool { times.count > 1 }

    public mutating func removeTime(at index: Int) {
        guard canRemoveTime, times.indices.contains(index) else { return }
        times.remove(at: index)
    }

    /// The time zone picker's choices (`timeZoneOptions`): UTC, every zone `known` to the
    /// platform, the draft's own and the device's, without repeats, sorted.
    public static func timeZoneOptions(current: String, device: String, known: [String]) -> [String] {
        let all = Set(["UTC", current, device].filter { !$0.isEmpty } + known)
        return all.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// How the picker shows a zone: "America/New York".
    public static func zoneLabel(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    /// The line under the editor: the schedule it would save, or "Fix the schedule above".
    public func preview(limits: Limits, isKnownTimeZone: (String) -> Bool = ScheduleDraft.isKnownTimeZone) -> String {
        switch validated(limits: limits, isKnownTimeZone: isKnownTimeZone) {
        case .success(let schedule): ScheduleText.describe(schedule)
        case .failure: "Fix the schedule above"
        }
    }

    /// The editor's copy.
    public static let noScheduleText = "No reminders. Add a schedule to see when it’s due and get notified."
    public static let intervalHint = "Counted from your latest entry"
    public static let notifyTitle = "Notify me when it’s due"
    public static let notifyHint = "Needs notifications on in Settings"
}
