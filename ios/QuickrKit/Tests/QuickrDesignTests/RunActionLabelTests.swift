import Foundation
import QuickrCore
import Testing

@testable import QuickrUI

/// active-surfaces.md §1.3 over every `RunAction.Kind`: the title, the SF Symbol and the VoiceOver
/// text each surface renders.
@Suite struct RunActionLabelTests {
    static let target = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// (kind, title, systemImage, spokenTitle for the topic "Morning").
    static let table: [(RunAction.Kind, String, String, String)] = [
        (.start, "Start", "play", "Start Morning"),
        (.next(label: "Shower"), "Next: Shower", "chevron.right", "Next: Shower"),
        (.next(label: "Next"), "Next", "chevron.right", "Next"),
        (.lap(nextTypeLabel: nil), "Lap", "flag", "Lap"),
        (.lap(nextTypeLabel: "Rest"), "Lap → Rest", "flag", "Lap, then Rest"),
        (.skip(label: "Breakfast"), "Skip Breakfast", "forward.end", "Skip Breakfast"),
        (.pause, "Pause", "pause", "Pause"),
        (.resume, "Resume", "play", "Resume"),
        (.stop, "Stop", "stop", "Stop Morning"),
        (.addDetails, "Add details", "pencil", "Add details to Morning"),
        (.reopen(target: target), "Resume run", "arrow.uturn.backward", "Resume the last run of Morning"),
        (.revert, "Undo resume…", "arrow.uturn.forward", "Undo the resume and keep the stop"),
        (.discard, "Discard run…", "trash", "Discard run"),
    ]

    @Test("§1.3 title, symbol and VoiceOver text per kind", arguments: table.indices)
    func row(_ index: Int) {
        let (kind, title, systemImage, spoken) = Self.table[index]
        let action = RunAction(kind: kind, role: .primary, enabled: true)
        #expect(action.title == title)
        #expect(action.systemImage == systemImage)
        #expect(action.spokenTitle(topic: "Morning") == spoken)
    }

    @Test("The table covers every kind")
    func coversEveryKind() {
        let ids = Set(Self.table.map { RunAction(kind: $0.0, role: .primary, enabled: true).id })
        #expect(
            ids == [
                "start", "next", "lap", "skip", "pause", "resume", "stop", "addDetails", "reopen", "revert", "discard",
            ])
    }
}
