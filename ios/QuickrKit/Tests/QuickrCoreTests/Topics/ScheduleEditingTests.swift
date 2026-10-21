import QuickrCore
import Testing

/// The schedule editor's controls (`ScheduleEditor.tsx`): day buttons and presets, "+ Time" and
/// the remove buttons, the zone list and the preview line.
@Suite struct ScheduleEditingTests {
    static let limits = Limits.serverDefaults

    static func daily(_ times: [String] = ["08:00"], days: [Int] = ScheduleDraft.allDays) -> ScheduleDraft {
        var draft = ScheduleDraft.empty(timezone: "Europe/London")
        draft.kind = .daily
        draft.times = times
        draft.days = days
        return draft
    }

    @Test func dayButtonsToggleAndKeepTheListSorted() {
        var draft = Self.daily(days: [1, 3])
        draft.toggleDay(2)
        #expect(draft.days == [1, 2, 3])
        draft.toggleDay(1)
        #expect(draft.days == [2, 3])
        draft.toggleDay(7)
        draft.toggleDay(5)
        #expect(draft.days == [2, 3, 5, 7])
    }

    @Test func aPresetIsSelectedOnlyForItsExactDays() {
        let weekdays = ScheduleDraft.dayPresets[1]
        #expect(weekdays.label == "Weekdays")
        #expect(Self.daily(days: [5, 4, 3, 2, 1]).isSelected(weekdays))
        #expect(!Self.daily(days: [1, 2, 3, 4]).isSelected(weekdays))
        #expect(Self.daily().isSelected(ScheduleDraft.dayPresets[0]))
        #expect(!Self.daily().isSelected(ScheduleDraft.dayPresets[2]))
    }

    @Test func addTimeFollowsTheLastAndStopsAtTheLimit() {
        var draft = Self.daily(["08:00"])
        draft.addTime(limits: Self.limits)
        #expect(draft.times == ["08:00", "20:00"])
        draft.addTime(limits: Self.limits)
        #expect(draft.times == ["08:00", "20:00", "12:00"], "08:00 is taken, so 12:00")

        var full = Self.daily((0..<24).map { ($0 < 10 ? "0" : "") + "\($0):00" })
        #expect(!full.canAddTime(limits: Self.limits))
        full.addTime(limits: Self.limits)
        #expect(full.times.count == 24)
    }

    @Test func theLastTimeCantBeRemoved() {
        var draft = Self.daily(["08:00", "20:00"])
        draft.removeTime(at: 0)
        #expect(draft.times == ["20:00"])
        #expect(!draft.canRemoveTime)
        draft.removeTime(at: 0)
        #expect(draft.times == ["20:00"])
        draft.removeTime(at: 5)
        #expect(draft.times == ["20:00"])
    }

    @Test func zoneOptionsIncludeUTCTheCurrentAndTheDeviceOnce() {
        let options = ScheduleDraft.timeZoneOptions(
            current: "Etc/Custom", device: "Europe/London", known: ["Europe/London", "America/New_York"])
        #expect(options == ["America/New_York", "Etc/Custom", "Europe/London", "UTC"])
        #expect(ScheduleDraft.zoneLabel("America/New_York") == "America/New York")
    }

    @Test func thePreviewDescribesOrAsksForAFix() {
        #expect(
            Self.daily(["08:00", "21:00"], days: [1, 2, 3, 4, 5]).preview(limits: Self.limits)
                == "Daily 08:00, 21:00 · weekdays")
        #expect(Self.daily(["8"]).preview(limits: Self.limits) == "Fix the schedule above")
        #expect(ScheduleDraft.empty(timezone: "UTC").preview(limits: Self.limits) == "No schedule")
    }

    @Test func detailsChangeIsNilWhenNothingDiffers() throws {
        let topic = Topic(
            id: .init(), slug: "mood", name: "Mood", description: "", currentVersion: 1, revision: 1,
            questionCount: 0, createdAt: .distantPast, updatedAt: .distantPast, questions: [])
        let same = try TopicDraft.editing(name: "Mood", slug: "mood", description: "", questions: [])
            .validatedDetails().get()
        #expect(TopicDetailsChange(same, from: topic) == nil)
        let renamed = try TopicDraft.editing(name: "Feelings", slug: "mood", description: "", questions: [])
            .validatedDetails().get()
        #expect(TopicDetailsChange(renamed, from: topic) == TopicDetailsChange(name: "Feelings"))
    }
}
