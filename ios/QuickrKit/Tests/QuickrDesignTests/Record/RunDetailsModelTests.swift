import Foundation
import QuickrCore
import QuickrUI
import Synchronization
import Testing

/// The answers form after Stop (`RunDetailsModel`, timers.md §3.6, §11.2): Save sends `finish`;
/// a refusal lands on the fields; `run_open` keeps the typed answers; a fix resends its item.
@MainActor @Suite struct RunDetailsModelTests {
    final class Finisher: RunFinishing {
        struct Sent: Sendable, Hashable {
            var runId: String?
            var itemId: String?
            var answers: [String: AnswerValue]
            var notes: String?
        }

        private let state = Mutex<(sent: [Sent], delivery: RunFinishDelivery)>(([], .sent))
        var sent: [Sent] { state.withLock { $0.sent } }
        func answer(_ delivery: RunFinishDelivery) { state.withLock { $0.delivery = delivery } }

        func finish(runId: String, answers: [String: AnswerValue], notes: String?) async -> RunFinishDelivery {
            state.withLock { state in
                state.sent.append(Sent(runId: runId, answers: answers, notes: notes))
                return state.delivery
            }
        }

        func refix(itemId: String, answers: [String: AnswerValue], notes: String?) async -> RunFinishDelivery {
            state.withLock { state in
                state.sent.append(Sent(itemId: itemId, answers: answers, notes: notes))
                return state.delivery
            }
        }
    }

    let questions = [
        Question(
            key: "mood", label: "Mood", required: true,
            kind: .choice(
                .init(options: [EnumOption(value: "good", label: "Good"), EnumOption(value: "bad", label: "Bad")])))
    ]
    let finisher = Finisher()

    private func model(fix: RunDetailsFix? = nil) -> RunDetailsModel {
        RunDetailsModel(topicName: "Morning", runId: "r1", questions: questions, fix: fix, finisher: finisher)
    }

    @Test func saveSendsFinishWithTheAnswersAndNotes() async {
        let model = model()
        _ = model.form.change("mood", to: .text("good"))
        model.notes = "  slow start "
        let outcome = await model.save()
        #expect(outcome == .leave)
        let sent = finisher.sent
        #expect(sent.count == 1)
        let first = sent[0]
        #expect(first.runId == "r1")
        #expect(first.answers == ["mood": .string("good")])
        #expect(first.notes == "slow start")
        let message: String? = model.savedMessage
        #expect(message == "Saved Morning")
    }

    @Test func aMissingRequiredAnswerSendsNothing() async {
        let model = model()
        let outcome = await model.save()
        #expect(outcome == .stay)
        let count = finisher.sent.count
        #expect(count == 0)
        let error: String? = model.form.errors["mood"]
        #expect(error != nil)
    }

    @Test func noAutoSaveOnASingleChipQuestion() {
        let model = model()
        let key: String? = model.form.autoSaveKey
        #expect(key == nil)
    }

    @Test func aRefusalLandsOnTheFields() async {
        finisher.answer(
            .failed(
                message: "422",
                problem: Problem(
                    code: .invalidAnswers, detail: "Some answers need attention",
                    errors: [FieldIssue(location: [.key("answers"), .key("mood")], message: "Not allowed")])))
        let model = model()
        _ = model.form.change("mood", to: .text("bad"))
        let outcome = await model.save()
        #expect(outcome == .stay)
        let error: String? = model.form.errors["mood"]
        #expect(error == "Not allowed")
    }

    @Test func runOpenKeepsTheTypedAnswers() async {
        finisher.answer(.runOpen)
        let model = model()
        _ = model.form.change("mood", to: .text("good"))
        let outcome = await model.save()
        #expect(outcome == .stay)
        let input = model.form.input(for: "mood")
        #expect(input == .text("good"))
        let banner: String? = model.banner
        #expect(banner != nil)
        #expect(model.hasUnsavedChanges)
        // Sent again once the stop is in.
        finisher.answer(.sent)
        let again = await model.save()
        #expect(again == .leave)
    }

    @Test func aFixResendsItsItemWithItsAnswers() async {
        let fix = RunDetailsFix(
            itemId: "item-1", answers: ["mood": .string("bad")], notes: "n", problem: nil, message: "Rejected")
        let model = model(fix: fix)
        #expect(model.isFixing)
        let input = model.form.input(for: "mood")
        #expect(input == .text("bad"))
        let banner: String? = model.banner
        #expect(banner == "Rejected")
        _ = model.form.change("mood", to: .text("good"))
        let outcome = await model.save()
        #expect(outcome == .leave)
        let sent = finisher.sent
        let first = sent[0]
        #expect(first.itemId == "item-1")
        #expect(first.answers == ["mood": .string("good")])
    }
}
