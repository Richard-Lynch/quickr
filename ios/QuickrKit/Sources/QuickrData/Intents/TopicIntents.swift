import AppIntents
import Foundation
import GRDB
import QuickrCore

/// Re-logs a topic's latest entry (PLAN §2 "Repeat-last"): the Action button's intent. If its
/// answers still validate against the current version they are logged again (a new entry, random
/// id); otherwise, or with no entry yet, the app opens on the record screen, prefilled with what
/// still applies. An archived or missing topic gets a dialog. Undoable.
public struct RepeatLastEntryIntent: AppIntent, UndoableIntent {
    public static let title: LocalizedStringResource = "Log Same as Last Time"
    public static let description = IntentDescription("Logs a topic's last entry again in quickR.")
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Topic") public var topic: TopicEntity

    public static var parameterSummary: some ParameterSummary { Summary("Log \(\.$topic) same as last time") }

    public init() {}

    public init(topic: TopicEntity) {
        self.topic = topic
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let context = IntentWrites.context() else { throw IntentLogging.Failure.noStore }
        let (current, plan, scope) = try await IntentLogging.repeatPlan(topicId: topic.id, in: context)
        switch plan {
        case .log(let answers):
            let logged = try await IntentLogging.log(topicId: current.id, answers: answers, in: context)
            let summary = IntentText.summary(logged.answers, topic: logged.topic)
            await IntentUndo.register(undoManager, logged: logged, context: context)
            return .result(value: summary, dialog: "Logged \(summary) again.")
        case .openRecord(let prefill):
            let reason =
                prefill == nil
                ? "\(current.name) has no entry to repeat yet." : "\(current.name)'s last entry no longer fits."
            try await continueInForeground("\(reason) Open quickR to log it?")
            await IntentNavigation.open(
                .record(topicId: current.id, prefill: IntentNavigation.prefillTexts(prefill ?? [:]), scope: scope))
            return .result(value: current.name, dialog: "Opening \(current.name) in quickR.")
        }
    }
}

/// Opens quickR on a topic's record screen.
public struct OpenRecordIntent: AppIntent {
    public static let title: LocalizedStringResource = "Record Entry"
    public static let description = IntentDescription("Opens quickR to record an entry for a topic.")
    public static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Topic") public var topic: TopicEntity

    public static var parameterSummary: some ParameterSummary { Summary("Record \(\.$topic)") }

    public init() {}

    public init(topic: TopicEntity) {
        self.topic = topic
    }

    public func perform() async throws -> some IntentResult {
        guard let context = IntentWrites.context() else { throw IntentLogging.Failure.noStore }
        let (store, current) = try await IntentLogging.topic(topic.id, in: context)
        await IntentNavigation.open(.record(topicId: current.id, prefill: [:], scope: store.scope))
        return .result()
    }
}

/// "What's due in quickR": the active store's topics that are due now (at device time plus the
/// server's measured skew, like the badge), said in the dialog (Siri AI may show no snippet).
public struct WhatsDueIntent: AppIntent {
    public static let title: LocalizedStringResource = "What's Due"
    public static let description = IntentDescription("Says which quickR topics are due now.")
    public static let supportedModes: IntentModes = .background

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[TopicEntity]> & ProvidesDialog {
        guard let context = IntentWrites.context() else { throw IntentLogging.Failure.noStore }
        let due = try await IntentDue.dueTopics(in: context)
        return .result(value: due.map(TopicEntity.init), dialog: "\(IntentText.dueSentence(due.map(\.name)))")
    }
}

/// The due topics, as `WhatsDueIntent` (and later its snippet) shows them.
public enum IntentDue {
    /// Active topics due now in the active store's view, in the list's order (most overdue
    /// first, like Home's "Due" section).
    public static func dueTopics(in context: IntentWriteContext) async throws -> [Topic] {
        guard let store = try? await context.openActiveStore() else { throw IntentLogging.Failure.noStore }
        let wall = context.wallClock.now()
        return try await store.writer.read { db in
            let state = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))
            let now = (state?.serverClock ?? .device).now(at: wall)
            return dueNow(try StoreView.dueTopics(db).map(\.topic), now: now)
        }
    }

    /// `topics` due at `now` (active, `DueView.isDueNow`), longest due first.
    static func dueNow(_ topics: [Topic], now: Date) -> [Topic] {
        topics.compactMap { topic -> (Topic, Date)? in
            guard topic.status == .active, let due = TopicListing.due(of: topic, at: now),
                DueView.isDueNow(due, now: now)
            else { return nil }
            return (topic, due.dueSince ?? due.nextDueAt ?? now)
        }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
        .map(\.0)
    }
}

/// The undo an intent registers after it logged (`UndoableIntent`): cancels that create, in the
/// store it was committed to.
public enum IntentUndo {
    final class Target: Sendable {
        static let shared = Target()
    }

    @MainActor
    public static func register(_ undoManager: UndoManager?, logged: IntentLogging.Logged, context: IntentWriteContext)
    {
        undoManager?.registerUndo(withTarget: Target.shared) { _ in
            Task { try? await IntentLogging.undo(logged, in: context) }
        }
        undoManager?.setActionName("Log \(IntentText.summary(logged.answers, topic: logged.topic))")
    }
}
