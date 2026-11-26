import Foundation
import Observation
import QuickrData
import SwiftUI
import UIKit

/// T2-M1 (timers2.md §9.1): a run alert that arrived while the app was in the foreground. Its
/// banner and sound are the system's (`NotificationResponder.willPresent`); this holds what the
/// app adds: the haptic's trigger (`presented`, played once at the root) and the alert's label,
/// which the run screen shows inline for 10 s (`label(runId:)`, read by M2's run screen). Not
/// `RunPresentation.alertLine`, which is the next alert's countdown.
@MainActor @Observable
final class RunAlertPresence {
    struct Shown: Equatable {
        /// Lowercase.
        var runId: String
        var label: String
        /// Which presentation this is: a second alert restarts the 10 s.
        var serial: Int
    }

    static let inlineDuration: Duration = .seconds(10)

    /// The latest alert, for its 10 s.
    private(set) var shown: Shown?
    /// One more per alert presented: the trigger of `QuickrHaptic.alert`.
    private(set) var presented = 0

    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var clearing: Task<Void, Never>?

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// The alert label to show inline on `runId`'s screen, while it is shown.
    func label(runId: String) -> String? {
        guard let shown, shown.runId == runId.lowercased() else { return nil }
        return shown.label
    }

    /// A run alert's `quickr` info arrived in the foreground: play the haptic and show its label.
    func present(_ info: QuickrNotificationInfo) {
        guard info.kind == RunAlerts.kind else { return }
        presented += 1
        guard let runId = info.runId, let label = info.alertLabel else { return }
        let serial = presented
        shown = Shown(runId: runId.lowercased(), label: label, serial: serial)
        clearing?.cancel()
        let sleep = sleep
        clearing = Task { [weak self] in
            do { try await sleep(Self.inlineDuration) } catch { return }
            guard let self, self.shown?.serial == serial else { return }
            self.shown = nil
        }
    }
}

extension AppEnvironment {
    /// The scheduler over the session's notification center (the system's in the app).
    private func runAlertScheduler(_ session: AppSession) -> RunAlertScheduler {
        if let scheduler = runAlertScheduler { return scheduler }
        let scheduler = RunAlertScheduler(center: session.configuration.categoryCenter ?? SystemNotificationCenter())
        runAlertScheduler = scheduler
        return scheduler
    }

    /// Keeps the pending run alerts in line with the bound store's local view (timers2.md §9.1):
    /// on every change to it (this device's taps, sync applying a page) and whenever the app
    /// becomes active. A Live Activity push runs no app code, so it isn't a trigger (OQ-11).
    /// Run it keyed by `session.binding`; with no bound store, every run alert is cancelled.
    func observeRunsForAlerts() async {
        guard let session else { return }
        let scheduler = runAlertScheduler(session)
        guard let store = session.store else {
            await scheduler.cancelAll()
            return
        }
        let refresh = session.refresh.stream()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    for try await input in store.observeRunAlerts(refresh: refresh) {
                        await scheduler.reconcile(input)
                    }
                } catch {
                    // The screens' own observations report store failures.
                }
            }
            group.addTask {
                let active = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
                for await _ in active.map({ _ in () }) {
                    guard let input = try? await store.runAlertInput() else { continue }
                    await scheduler.reconcile(input)
                }
            }
        }
    }

    /// M1-REVIEW P1-2: reschedules the run alerts from `store` once, after a write made outside
    /// `RootView` (a Live Activity button or a run intent: iOS runs them in a background launch,
    /// or wakes the suspended app just for them, so `observeRunsForAlerts` isn't running). Call it
    /// while the store hold is still held, beside the Live Activity's reconcile.
    func rescheduleRunAlerts(_ store: LocalStore, session: AppSession) async {
        guard let input = try? await store.runAlertInput() else { return }
        await runAlertScheduler(session).reconcile(input)
    }

    /// `willPresent` of a run alert (`quickr.kind = alert`).
    func runAlertPresented(_ info: QuickrNotificationInfo) {
        runAlerts.present(info)
    }
}
