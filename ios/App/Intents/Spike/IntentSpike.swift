#if DEBUG
import AppIntents
import Foundation

/// SPIKE (INTENTS, research/04-siri.md §2): what a prompting intent can rely on. DEBUG only; never
/// shipped. `QuickRIntentsTests/IntentSpikeTests` drives them (opt-in, `QUICKR_INTENT_SPIKE=1`).
///
/// - `SpikePromptIntent` asks for the **same** parameter three times (`requestValue` in a loop) and
///   reports what each call returned and how long the user took: whether a parameter can be asked
///   again once it has a value, and whether time spent waiting for the user counts toward the
///   intent's ~30 s budget.
/// - `SpikeWorkIntent` works (sleeps) for `seconds` without prompting: the processing budget.
struct SpikePromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Spike Prompts"
    static let description = IntentDescription("SPIKE: asks for the same value three times.")

    @Parameter(title: "Value") var slot: Double?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let start = Date()
        var answers: [String] = []
        SpikeLog.append("intent.prompts.start", ["slot": slot.map { "\($0)" } ?? "nil"])
        for round in 1...3 {
            let asked = Date()
            let value = try await $slot.requestValue("Value \(round)?")
            let waited = Date().timeIntervalSince(asked)
            answers.append("\(round)=\(value.formatted()) (\(String(format: "%.1f", waited)) s)")
            SpikeLog.append("intent.prompts.answer", ["round": "\(round)", "value": "\(value)", "waited": "\(waited)"])
        }
        let summary =
            "SPIKE " + answers.joined(separator: ", ")
            + " total \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
        SpikeLog.append("intent.prompts.done", ["summary": summary])
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct SpikeWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Spike Work"
    static let description = IntentDescription("SPIKE: works for a number of seconds.")

    @Parameter(title: "Seconds", default: 5) var seconds: Int

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let start = ContinuousClock.now
        SpikeLog.append("intent.work.start", ["seconds": "\(seconds)"])
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            SpikeLog.append("intent.work.cancelled", ["after": "\(ContinuousClock.now - start)"])
            throw error
        }
        let summary = "SPIKE worked \(seconds) s, \(ContinuousClock.now - start)"
        SpikeLog.append("intent.work.done", ["summary": summary])
        return .result(value: summary)
    }
}
#endif
