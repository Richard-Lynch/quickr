import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/schedule-vectors.json`, from the PWA's own `schedule.ts`: the schedule
/// editor's validation (messages and order), the body it sends, the draft a saved schedule opens
/// as, its description, server error paths and the "+ Time" default.
@Suite struct ScheduleVectorTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            struct Limits: Decodable {
                var timePattern: String
                var scheduleMaxTimes: Int
                var intervalMinMinutes: Int
                var intervalMaxMinutes: Int
            }
            var timezone: String
            var limits: Limits
        }

        struct Draft: Decodable, Sendable {
            var kind: String
            var times: [String]
            var days: [Int]
            var timezone: String
            var every: String
            var unit: String
            var notify: Bool

            var model: ScheduleDraft {
                ScheduleDraft(
                    kind: ScheduleDraft.Kind(rawValue: kind)!, times: times, days: days, timezone: timezone,
                    every: every, unit: ScheduleDraft.Unit(rawValue: unit)!, notify: notify)
            }
        }

        /// The API's `schedule` (input or output shape).
        struct WireSchedule: Decodable, Sendable, Equatable {
            var kind: String
            var times: [String]?
            var days: [Int]?
            var everyMinutes: Int?
            var timezone: String
            var notify: Bool

            var model: Schedule {
                switch kind {
                case "daily":
                    .daily(
                        Schedule.Daily(
                            times: times!.map { TimeOfDay($0)! }, days: days ?? Schedule.Daily.everyDay,
                            timezone: timezone, notify: notify))
                default:
                    .interval(Schedule.Interval(everyMinutes: everyMinutes!, timezone: timezone, notify: notify))
                }
            }

            init(_ schedule: Schedule) {
                switch schedule {
                case .daily(let daily):
                    self.init(
                        kind: "daily", times: daily.times.map(\.description), days: daily.days, everyMinutes: nil,
                        timezone: daily.timezone, notify: daily.notify)
                case .interval(let interval):
                    self.init(
                        kind: "interval", times: nil, days: nil, everyMinutes: interval.everyMinutes,
                        timezone: interval.timezone, notify: interval.notify)
                }
            }

            init(
                kind: String, times: [String]?, days: [Int]?, everyMinutes: Int?, timezone: String, notify: Bool
            ) {
                self.kind = kind
                self.times = times
                self.days = days
                self.everyMinutes = everyMinutes
                self.timezone = timezone
                self.notify = notify
            }
        }

        enum PathPart: Decodable, Sendable, Equatable {
            case key(String)
            case index(Int)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let i = try? container.decode(Int.self) {
                    self = .index(i)
                } else {
                    self = .key(try container.decode(String.self))
                }
            }
        }

        struct Issue: Decodable, Sendable {
            var path: [PathPart]
            var message: String

            /// The PWA's draft path as the Swift field.
            var field: ScheduleField? {
                if path.count == 3, path[0] == .key("times"), path[2] == .key("value"), case .index(let i) = path[1] {
                    return .time(i)
                }
                switch path {
                case [.key("timezone")]: return .timezone
                case [.key("times")]: return .times
                case [.key("days")]: return .days
                case [.key("every")]: return .every
                default: return nil
                }
            }
        }

        struct Expected: Decodable, Sendable {
            var ok: Bool
            var schedule: WireSchedule?
            var issues: [Issue]?
        }

        struct Validate: Decodable, Sendable, CustomTestStringConvertible {
            var name: String
            var draft: Draft
            var expected: Expected
            var testDescription: String { name }
        }

        struct Describe: Decodable, Sendable, CustomTestStringConvertible {
            var schedule: WireSchedule?
            var expected: String
            var testDescription: String { expected }
        }

        struct Split: Decodable, Sendable, CustomTestStringConvertible {
            var minutes: Int
            var every: String
            var unit: String
            var testDescription: String { "\(minutes)" }
        }

        struct FromSchedule: Decodable, Sendable, CustomTestStringConvertible {
            var schedule: WireSchedule?
            var expected: Draft
            var testDescription: String { schedule.map { "\($0.kind) \($0.timezone)" } ?? "none" }
        }

        struct FieldFor: Decodable, Sendable, CustomTestStringConvertible {
            var path: String
            var expected: String?
            var testDescription: String { "\"\(path)\"" }
        }

        struct NextTime: Decodable, Sendable, CustomTestStringConvertible {
            var times: [String]
            var expected: String
            var testDescription: String { "\(times)" }
        }

        var meta: Meta
        var validate: [Validate]
        var describe: [Describe]
        var split: [Split]
        var fromSchedule: [FromSchedule]
        var fieldFor: [FieldFor]
        var nextTime: [NextTime]
    }

    static let vectors: Vectors = {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Vectors.self, from: Fixtures.data("schedule-vectors.json"))
        } catch {
            fatalError("schedule-vectors.json: \(error)")
        }
    }()

    static let limits = Limits.serverDefaults

    @Test func vectorsUseTheServerDefaults() {
        let meta = Self.vectors.meta.limits
        #expect(meta.timePattern == Self.limits.timePattern)
        #expect(meta.scheduleMaxTimes == Self.limits.scheduleMaxTimes)
        #expect(meta.intervalMinMinutes == Self.limits.intervalMinMinutes)
        #expect(meta.intervalMaxMinutes == Self.limits.intervalMaxMinutes)
        #expect(Self.vectors.validate.count > 40)
    }

    @Test(arguments: vectors.validate)
    func validatesLikeThePWA(_ vector: Vectors.Validate) throws {
        let result = vector.draft.model.validated(limits: Self.limits)
        if vector.expected.ok {
            let schedule = try result.get()
            #expect(schedule.map(Vectors.WireSchedule.init) == vector.expected.schedule)
        } else {
            guard case .failure(let issues) = result else {
                Issue.record("accepted: \(String(describing: try? result.get()))")
                return
            }
            let expected = try #require(vector.expected.issues)
            #expect(issues.issues.map(\.field) == expected.map(\.field))
            #expect(issues.issues.map(\.message) == expected.map(\.message))
        }
    }

    @Test(arguments: vectors.describe)
    func describesLikeThePWA(_ vector: Vectors.Describe) {
        #expect(ScheduleText.describe(vector.schedule?.model) == vector.expected)
    }

    @Test(arguments: vectors.split)
    func splitsLikeThePWA(_ vector: Vectors.Split) {
        let (every, unit) = ScheduleDraft.split(minutes: vector.minutes)
        #expect(every == vector.every)
        #expect(unit.rawValue == vector.unit)
    }

    @Test(arguments: vectors.fromSchedule)
    func opensLikeThePWA(_ vector: Vectors.FromSchedule) {
        let draft = ScheduleDraft(schedule: vector.schedule?.model, timezone: Self.vectors.meta.timezone)
        #expect(draft == vector.expected.model)
    }

    @Test(arguments: vectors.fieldFor)
    func mapsServerPathsLikeThePWA(_ vector: Vectors.FieldFor) {
        #expect(ScheduleField(serverPath: vector.path)?.path == vector.expected)
    }

    @Test(arguments: vectors.nextTime)
    func addsTimesLikeThePWA(_ vector: Vectors.NextTime) {
        #expect(ScheduleDraft.nextTime(after: vector.times) == vector.expected)
    }
}
