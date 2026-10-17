#if DEBUG
import Foundation
import QuickrCore
import QuickrUI
import SwiftUI

/// `-QuickrFormDemo <workout|types|fix>`: the answer form over fixed topics, with no data layer
/// (UI tests and screenshots). Save shows the body it would send under the form.
struct FormDemoView: View {
    enum Demo: String {
        /// The design loop's 4-question mixed topic, empty.
        case workout
        /// Every control, with "Same as last time" offered.
        case types
        /// A rejected entry back on the form.
        case fix
    }

    let demo: Demo
    @State private var model: FormModel
    @State private var submitted: String?

    init(demo: Demo) {
        self.demo = demo
        _model = State(initialValue: Self.model(for: demo))
    }

    var body: some View {
        NavigationStack {
            FormView(model: model, onAutoSave: show) {
                if let submitted {
                    Text(submitted)
                        .font(.qr(.monoCaption))
                        .foregroundStyle(.qr.inkSoft)
                        .accessibilityIdentifier("formDemo.body")
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(demo == .fix ? "Save again" : "Save", icon: .check) {
                    if let body = model.submit() { show(body) }
                }
                .accessibilityIdentifier("formDemo.save")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle(demo == .fix ? "Fix entry · Workout" : demo == .types ? "Check-in" : "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .qrPaperBackground()
        }
    }

    private func show(_ body: AnswersBody) {
        submitted = Self.json(body)
    }

    /// The body as sorted-key JSON, e.g. `{"duration":45,"type":"run"}`.
    static func json(_ body: AnswersBody) -> String {
        let answers: [String: JSONValue] =
            switch body {
            case .create(let map): map.mapValues(Self.json)
            case .update(let map): map.mapValues { $0.map(Self.json) ?? .null }
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(answers)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func json(_ value: AnswerValue) -> JSONValue {
        switch value {
        case .int(let n): .number(Double(n))
        case .double(let x): .number(x)
        case .string(let s): .string(s)
        case .strings(let values): .array(values.map(JSONValue.string))
        }
    }

    private static func model(for demo: Demo) -> FormModel {
        switch demo {
        case .workout:
            return FormModel(questions: workout)
        case .types:
            let last = LastEntry(
                answers: ["mood": .string("good"), "energy": .int(7), "factors": .strings(["sleep", "coffee"])],
                capturedAt: Date().addingTimeInterval(-26 * 3600))
            return FormModel(questions: checkIn, mode: .create(last: last))
        case .fix:
            let problem = Problem(
                code: .invalidAnswers, detail: "Some answers need attention",
                errors: [
                    FieldIssue(
                        location: [.key("body"), .key("answers"), .key("duration")],
                        message: "Must be at most 600 min"),
                    FieldIssue(location: [.key("body"), .key("answers"), .key("pace")], message: "Unknown question"),
                ])
            return FormModel(
                questions: workout,
                mode: .fix(answers: ["type": .string("run"), "duration": .int(900)], problem: problem))
        }
    }

    static let workout: [Question] = [
        Question(
            key: "type", label: "Type",
            kind: .choice(
                .init(options: [
                    EnumOption(value: "run", label: "Run"), EnumOption(value: "strength", label: "Strength"),
                    EnumOption(value: "yoga", label: "Yoga"), EnumOption(value: "swim", label: "Swim"),
                ]))),
        Question(key: "duration", label: "Duration", kind: .int(.init(min: 1, max: 600, unit: "min"))),
        Question(
            key: "distance", label: "Distance", required: false, kind: .double(.init(min: 0, decimals: 1, unit: "km"))),
        Question(key: "note", label: "How it felt", required: false, kind: .string(.init(maxLength: 200))),
    ]

    static let checkIn: [Question] = [
        Question(
            key: "mood", label: "Mood",
            kind: .choice(
                .init(options: [
                    EnumOption(value: "bad", label: "Bad"), EnumOption(value: "meh", label: "Meh"),
                    EnumOption(value: "good", label: "Good"),
                ]))),
        Question(
            key: "energy", label: "Energy", helpText: "1 is flat, 10 is bouncing off the walls.",
            kind: .int(.init(min: 1, max: 10))),
        Question(
            key: "factors", label: "Factors", required: false,
            kind: .choice(
                .init(
                    options: [
                        EnumOption(value: "sleep", label: "Sleep"), EnumOption(value: "coffee", label: "Coffee"),
                        EnumOption(value: "stress", label: "Stress"), EnumOption(value: "exercise", label: "Exercise"),
                    ], multiple: true, maxSelected: 2))),
        Question(
            key: "weather", label: "Weather", required: false,
            kind: .choice(
                .init(
                    options: ["Sunny", "Cloudy", "Rain", "Snow", "Wind", "Fog", "Storm"].map {
                        EnumOption(value: $0.lowercased(), label: $0)
                    }))),
        Question(key: "temp", label: "Outside", required: false, kind: .double(.init(min: -40, max: 50, unit: "°C"))),
        Question(
            key: "journal", label: "Journal", required: false,
            kind: .string(.init(maxLength: 280, multiline: true))),
    ]
}
#endif
