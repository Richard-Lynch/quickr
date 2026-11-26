import Foundation

/// Where a run's actions go on a surface (active-surfaces.md §1, D-1): the one primary, the
/// secondaries beside it, and the overflow menu. Placement reads `role` only, never `kind`, so a
/// kind M1 starts returning later (`reopen`, `revert`) lands in its role's slot with no edit here.
/// The input is `RunPresentation.actions(_:status:timer:now:)`, whose primary rule is timers2.md
/// §10's. The PWA's `components/runs/controlsLayout.ts`.
///
/// The run screen renders all three slots (§2.2); the home card renders `tile(actions:)` (§3.2).
/// The Live Activity and the widgets don't use it: they read `RunActivityDisplay` (§4.1, §5.1).
public struct RunControlsLayout: Sendable, Hashable {
    /// The `primary` action; nil when there is none (a closed run's `[]`, or row 13's lone
    /// `reopen`).
    public var primary: RunAction?
    /// The `secondary` actions in input order: Stop, then Pause or Resume; Resume run when idle.
    public var secondaries: [RunAction]
    /// The menu, in input order with every `destructive` action after the `overflow` ones. Also
    /// holds anything without a slot of its own: a second `primary` (there is exactly one, §1.2,
    /// so it never happens, but no action is ever dropped).
    public var overflow: [RunAction]

    /// Places `actions` by role. Every action lands in exactly one slot; `enabled` is passed
    /// through untouched, so a busy run (§1.2 row 14) keeps its layout with every button off.
    public init(actions: [RunAction]) {
        var primary: RunAction?
        var secondaries: [RunAction] = []
        var overflow: [RunAction] = []
        var destructive: [RunAction] = []
        for action in actions {
            switch action.role {
            case .primary where primary == nil: primary = action
            case .secondary: secondaries.append(action)
            case .destructive: destructive.append(action)
            case .primary, .overflow: overflow.append(action)
            }
        }
        self.primary = primary
        self.secondaries = secondaries
        self.overflow = overflow + destructive
    }

    /// The active home card's controls (active-surfaces.md §3.2): the primary and Stop in the
    /// controls row, Pause or Resume as the title row's text button. The card has no menu.
    public struct Tile: Sendable, Hashable {
        public var primary: RunAction?
        public var stop: RunAction?
        /// Pause while running, Resume while paused.
        public var pauseResume: RunAction?

        public init(primary: RunAction?, stop: RunAction?, pauseResume: RunAction?) {
            self.primary = primary
            self.stop = stop
            self.pauseResume = pauseResume
        }
    }

    /// The card's three controls, from the secondaries' Stop and Pause/Resume. §3.2 puts those two
    /// in different rows, the one place a kind picks a slot; other secondaries (an idle topic's
    /// Resume run) are not the card's: the idle tile renders them (§3.3).
    public static func tile(actions: [RunAction]) -> Tile {
        let layout = RunControlsLayout(actions: actions)
        return Tile(
            primary: layout.primary,
            stop: layout.secondaries.first { $0.kind == .stop },
            pauseResume: layout.secondaries.first { $0.kind == .pause || $0.kind == .resume })
    }
}
