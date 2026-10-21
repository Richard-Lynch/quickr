#if DEBUG
import QuickrCore
import QuickrData
import SwiftUI

/// `-QuickrSnippetGallery`: LogTopicIntent's confirmation snippet (`EntryDraftSnippet`, the view
/// Siri shows) over demo drafts, each on a plate shaped like the system's confirmation card, for
/// the milestone screenshots. The drafts are held in `IntentDrafts`, so the chips, toggles and ±
/// run their intents as they do in Siri, and the cards re-read them. The dialog and buttons around
/// the snippet are an approximation: the system's own card is captured on a device (M4-DEV W4, W9).
struct SnippetGalleryView: View {
    @State private var drafts: [IntentDraft] = Self.demoDrafts()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForEach(drafts) { draft in card(draft) }
            }
            .padding(16)
        }
        .background(LinearGradient(colors: [.indigo, .teal], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .accessibilityIdentifier("snippet.gallery")
        .task {
            // The snippet's buttons change the held drafts; show what they hold.
            while !Task.isCancelled {
                drafts = drafts.map { IntentDrafts.get($0.id) ?? $0 }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func card(_ draft: IntentDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("quickR", systemImage: "checkmark.circle.fill").font(.footnote.bold()).foregroundStyle(.secondary)
            Text("Log \(IntentText.summary(draft.answers, topic: draft.topic))?").font(.headline)
            EntryDraftSnippet(draft: draft)
            HStack {
                Text("Cancel").frame(maxWidth: .infinity)
                Text("Log").bold().frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
            .background(.quaternary, in: Capsule())
            .accessibilityHidden(true)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snippet.card.\(draft.topic.slug)")
    }

    /// A workout with every answer (numbers, chips, an optional note), and a check-in whose
    /// multi-select is still short of its minimum (the problem line).
    static func demoDrafts() -> [IntentDraft] {
        let workout = topic(
            1, "workout", "Workout",
            [
                Question(key: "minutes", label: "Minutes", kind: .int(.init(min: 1, max: 300, unit: "min"))),
                Question(
                    key: "kind", label: "Kind",
                    kind: .choice(
                        .init(options: ["Run", "Gym", "Swim"].map { EnumOption(value: $0.lowercased(), label: $0) }))),
                Question(key: "effort", label: "Effort", kind: .int(.init(min: 1, max: 10))),
                Question(key: "note", label: "Note", required: false, kind: .string(.init())),
            ])
        let checkIn = topic(
            2, "check-in", "Check-in",
            [
                Question(
                    key: "symptoms", label: "Symptoms",
                    kind: .choice(
                        .init(
                            options: ["Headache", "Nausea", "Fatigue"].map {
                                EnumOption(value: $0.lowercased(), label: $0)
                            }, multiple: true, minSelected: 1))),
                Question(key: "sleep", label: "Sleep", kind: .double(.init(min: 0, max: 24, decimals: 1, unit: "h"))),
            ])
        let drafts = [
            IntentDraft(
                topic: workout, answers: ["minutes": .int(30), "kind": .string("run"), "effort": .int(7)]),
            IntentDraft(topic: checkIn, answers: ["symptoms": .strings([]), "sleep": .double(7.5)]),
        ]
        drafts.forEach(IntentDrafts.put)
        return drafts
    }

    private static func topic(_ n: Int, _ slug: String, _ name: String, _ questions: [Question]) -> Topic {
        Topic(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8100-%012d", n))!, slug: slug, name: name,
            currentVersion: 1, revision: 1, questionCount: questions.count, createdAt: .now, updatedAt: .now,
            questions: questions)
    }
}
#endif
