import Foundation
import QuickrCore
import Synchronization

/// How an intent opens a screen in this process: the app registers its router at launch
/// (`OpenRecordIntent`, and repeat-last falling back to the record screen). Like
/// `IntentTopicSource`, a process-wide registration rather than `@Dependency`.
public enum IntentNavigation {
    /// What to open.
    public enum Request: Sendable, Hashable {
        /// A topic's record screen, prefilled with each question's text (numbers and single
        /// options; a multi-select isn't prefilled). `scope` is the store the topic and the
        /// prefill were read from: the app opens it only while that store is active
        /// (notifications.md §7.5).
        case record(topicId: UUID, prefill: [String: String], scope: EntryScope)
    }

    private static let handler = Mutex<(@MainActor @Sendable (Request) async -> Void)?>(nil)

    public static func register(_ open: @escaping @MainActor @Sendable (Request) async -> Void) {
        handler.withLock { $0 = open }
    }

    /// Opens `request` (returning once the app has opened it or said why not); false when no
    /// process registered a handler (the widget extension).
    @discardableResult
    public static func open(_ request: Request) async -> Bool {
        guard let open = handler.withLock({ $0 }) else { return false }
        await open(request)
        return true
    }

    /// The record screen's prefill text for `answers`: an int or double as the form would print
    /// it, a single option's value. Multi-select answers are left out.
    public static func prefillTexts(_ answers: [String: AnswerValue]) -> [String: String] {
        answers.compactMapValues { answer in
            switch answer {
            case .int(let n): String(n)
            case .double(let x): JSNumber.string(x)
            case .string(let value): value
            case .strings: nil
            }
        }
    }
}
