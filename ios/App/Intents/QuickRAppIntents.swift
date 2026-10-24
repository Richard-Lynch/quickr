import AppIntents
import QuickrData

/// The package's intents (`TopicEntity`, `LogEntryIntent`, …) reach this target's metadata by
/// linking QuickrData; there is deliberately no `AppIntentsPackage` (see `QuickrDataIntents.swift`).
///
/// The only `AppShortcutsProvider`, and it must stay in the app target (research/04-siri.md §5:
/// every phrase names the app, at most one entity parameter per phrase, at most 10 shortcuts:
/// `IntentMetadataTests` counts them).
/// `AppEnvironment.start()` refreshes the topic parameters; STORE calls it again after topic changes.
struct QuickRShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Any topic: its questions asked one per turn, then a confirmation snippet. A quick-log
        // topic is just its one question. `LogEntryIntent` stays an action (Shortcuts, widgets).
        AppShortcut(
            intent: LogTopicIntent(),
            phrases: [
                "Log \(\.$topic) in \(.applicationName)",
                "Log an entry in \(.applicationName)",
            ],
            shortTitle: "Log Entry",
            systemImageName: "plus.circle"
        )
        // The Action button's natural choice: one press re-logs (PLAN §2 "Repeat-last").
        AppShortcut(
            intent: RepeatLastEntryIntent(),
            phrases: [
                "Same \(\.$topic) as last time in \(.applicationName)",
                "Log \(\.$topic) again in \(.applicationName)",
            ],
            shortTitle: "Same as Last Time",
            systemImageName: "arrow.clockwise.circle"
        )
        AppShortcut(
            intent: OpenRecordIntent(),
            phrases: ["Record \(\.$topic) in \(.applicationName)", "Open \(\.$topic) in \(.applicationName)"],
            shortTitle: "Record Entry",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: WhatsDueIntent(),
            phrases: ["What's due in \(.applicationName)", "What do I need to log in \(.applicationName)"],
            shortTitle: "What's Due",
            systemImageName: "clock"
        )
        // Timed topics (timers.md §11.3): one parameterised shortcut for every run action. A
        // phrase takes one parameter, so an action phrase acts on the only open run (several are
        // asked), and a topic phrase runs Auto ("Next": start, next step, or stop on the last).
        AppShortcut(
            intent: RunActionIntent(),
            phrases: [
                "\(\.$action) the timer in \(.applicationName)",
                "\(\.$action) my timer in \(.applicationName)",
                "Time \(\.$topic) in \(.applicationName)",
                "Next \(\.$topic) in \(.applicationName)",
                "\(\.$topic) timer in \(.applicationName)",
            ],
            shortTitle: "Timer",
            systemImageName: "timer"
        )
        #if DEBUG
        // SPIKE (INTENTS): runs from the Shortcuts app, which answers prompts on the simulator.
        AppShortcut(
            intent: SpikePromptIntent(),
            phrases: ["Spike prompts in \(.applicationName)"],
            shortTitle: "Spike Prompts",
            systemImageName: "questionmark.bubble"
        )
        #endif
    }
}
