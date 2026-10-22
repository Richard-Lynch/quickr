import Observation
import QuickrData
import QuickrUI
import SwiftUI

/// What `ResetFlow` needs from the session (`AppSession` in the app, a fake in tests).
@MainActor
protocol LocalReset: AnyObject {
    func resetWarning() async throws -> SyncCoordinator.ResetWarning?
    /// Sends what can be sent now.
    func flushForReset() async
    func performReset(confirmed: SyncCoordinator.ResetWarning) async throws -> SyncCoordinator.ResetOutcome
}

extension AppSession: LocalReset {
    func resetWarning() async throws -> SyncCoordinator.ResetWarning? {
        try await coordinator.resetWarning()
    }

    func flushForReset() async {
        _ = await scheduler?.flushNow(reason: .enqueue)
    }

    func performReset(confirmed: SyncCoordinator.ResetWarning) async throws -> SyncCoordinator.ResetOutcome {
        try await coordinator.performReset(confirmed: confirmed)
    }
}

/// Settings ▸ "Reset local data" (sync-protocol.md §12.1). Nothing pending: one confirmation.
/// Otherwise "N changes haven't synced (k failed)" with **Sync first** (flush, then reset if
/// nothing is left, or ask again with what is), **Reset anyway** (a second, destructive
/// confirmation) and **Cancel**. Then reset, and report.
@MainActor @Observable
final class ResetFlow {
    enum State: Equatable {
        case idle
        case loading
        /// The first confirmation. `afterSync`: a "Sync first" didn't send everything.
        case confirm(SyncCoordinator.ResetWarning, afterSync: Bool)
        case syncing
        /// "Reset anyway"'s second, destructive confirmation.
        case confirmLoss(SyncCoordinator.ResetWarning)
        case resetting
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let reset: any LocalReset

    init(reset: any LocalReset) {
        self.reset = reset
    }

    convenience init(session: AppSession) {
        self.init(reset: session)
    }

    var isBusy: Bool { [.loading, .syncing, .resetting].contains(state) }

    func begin() async {
        state = .loading
        await loadWarning(afterSync: false)
    }

    func cancel() {
        state = .idle
    }

    /// The first confirmation's "Reset" (nothing pending). The state moves before this returns,
    /// so the dialog's dismissal sees it.
    func confirmed() {
        guard case .confirm(let warning, _) = state, !warning.needsDestructiveConfirmation else { return }
        start(warning)
    }

    /// "Reset anyway": the second confirmation.
    func resetAnyway() {
        guard case .confirm(let warning, _) = state, warning.needsDestructiveConfirmation else { return }
        state = .confirmLoss(warning)
    }

    /// The second confirmation.
    func confirmedLoss() {
        guard case .confirmLoss(let warning) = state else { return }
        start(warning)
    }

    /// "Sync first": flush, then reset if nothing is left, otherwise ask again with what is.
    func syncFirst() {
        guard case .confirm = state else { return }
        state = .syncing
        Task {
            await reset.flushForReset()
            await loadWarning(afterSync: true)
        }
    }

    private func loadWarning(afterSync: Bool) async {
        do {
            guard let warning = try await reset.resetWarning() else {
                state = .failed("There’s no server to reset yet.")
                return
            }
            if afterSync && !warning.needsDestructiveConfirmation {
                // Everything went: the user already chose to reset.
                state = .resetting
                await perform(warning)
            } else {
                state = .confirm(warning, afterSync: afterSync)
            }
        } catch {
            state = .failed("Couldn’t check what would be lost, so nothing was reset: \(error)")
        }
    }

    private func start(_ warning: SyncCoordinator.ResetWarning) {
        state = .resetting
        Task { await perform(warning) }
    }

    private func perform(_ warning: SyncCoordinator.ResetWarning) async {
        do {
            switch try await reset.performReset(confirmed: warning) {
            case .completed:
                state = .done("Done. Everything was reloaded from the server.")
            case .writesArrived(let newer):
                // Something was logged since the warning: confirm again with the new numbers.
                state = .confirm(newer, afterSync: false)
            case .timedOut:
                state = .failed("Sync didn’t pause in time, so nothing was reset. Try again.")
            case .superseded:
                state = .failed("The server changed while resetting, so nothing was reset.")
            case .noActiveStore:
                state = .failed("There’s no server to reset.")
            }
        } catch {
            state = .failed("Reset failed: \(error)")
        }
    }

    /// The first confirmation's text.
    nonisolated static func message(count: Int, failedCount: Int, afterSync: Bool = false) -> String {
        let reload = "quickR deletes its copy on this iPhone and loads everything again from the server."
        guard count > 0 else { return reload + " Nothing is lost." }
        let changes = count == 1 ? "1 change hasn’t" : "\(count) changes haven’t"
        let failed = failedCount > 0 ? " (\(failedCount) failed)" : ""
        let retry = afterSync ? "Syncing didn’t send everything. " : ""
        return "\(retry)\(changes) synced\(failed). Sync first to send them, or reset anyway and lose them."
    }

    /// The second confirmation's text: what is lost.
    nonisolated static func lossMessage(count: Int, failedCount: Int) -> String {
        let changes = count == 1 ? "1 change that hasn’t" : "\(count) changes that haven’t"
        let failed = failedCount > 0 ? " (\(failedCount) of them failed to sync)" : ""
        return "This deletes \(changes) synced\(failed). They can’t be recovered."
    }

    nonisolated static func lossLabel(count: Int) -> String {
        count == 1 ? "Delete 1 change and reset" : "Delete \(count) changes and reset"
    }
}

struct ResetSection: View {
    let flow: ResetFlow

    var body: some View {
        Section {
            Button(role: .destructive) {
                Task { await flow.begin() }
            } label: {
                HStack {
                    Text("Reset local data…")
                    if flow.isBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(flow.isBusy)
            .accessibilityIdentifier("settings.reset")
            switch flow.state {
            // Each outcome is read as it appears (the dialogs have closed and VoiceOver is back on
            // the disabled Reset button; audit SE5).
            case .syncing:
                Text("Sending your changes…").foregroundStyle(.qr.muted)
                    .onAppear { QuickrAnnouncer.announce("Sending your changes") }
            case .done(let message):
                Text(message).foregroundStyle(QuickrTone.ok.foreground).accessibilityIdentifier("settings.resetDone")
                    .qrMovesVoiceOverFocus(on: message)
            case .failed(let message):
                Text(message).foregroundStyle(QuickrTone.danger.foreground)
                    .qrAnnouncesError(message)
            default:
                EmptyView()
            }
        } header: {
            Text("Local data")
        } footer: {
            Text("Reloads this server’s data from scratch. Other servers’ data and the token stay.")
        }
        .confirmationDialog(
            first.map { $0.warning.needsDestructiveConfirmation ? "Changes haven’t synced" : "Reset local data?" }
                ?? "",
            isPresented: presented(first.map { ResetFlow.State.confirm($0.warning, afterSync: $0.afterSync) }),
            titleVisibility: .visible, presenting: first
        ) { pending in
            if pending.warning.needsDestructiveConfirmation {
                Button("Sync first") { flow.syncFirst() }
                Button("Reset anyway…", role: .destructive) { flow.resetAnyway() }
            } else {
                Button("Reset", role: .destructive) { flow.confirmed() }
            }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { pending in
            Text(
                ResetFlow.message(
                    count: pending.warning.count, failedCount: pending.warning.failedCount, afterSync: pending.afterSync
                ))
        }
        .confirmationDialog(
            "Delete unsynced changes?", isPresented: presented(second.map(ResetFlow.State.confirmLoss)),
            titleVisibility: .visible, presenting: second
        ) { warning in
            Button(ResetFlow.lossLabel(count: warning.count), role: .destructive) { flow.confirmedLoss() }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { warning in
            Text(ResetFlow.lossMessage(count: warning.count, failedCount: warning.failedCount))
        }
    }

    private var first: (warning: SyncCoordinator.ResetWarning, afterSync: Bool)? {
        if case .confirm(let warning, let afterSync) = flow.state { return (warning, afterSync) }
        return nil
    }

    private var second: SyncCoordinator.ResetWarning? {
        if case .confirmLoss(let warning) = flow.state { return warning }
        return nil
    }

    /// The dialog for `stage` is up while the flow is there. Dismissing it by tapping outside
    /// cancels; a button's action may run after the dismissal, so the cancel waits a turn and only
    /// applies if the flow is still at this dialog's stage.
    private func presented(_ stage: ResetFlow.State?) -> Binding<Bool> {
        Binding(
            get: { stage != nil },
            set: { shown in
                guard !shown, let stage else { return }
                Task { @MainActor in
                    if flow.state == stage { flow.cancel() }
                }
            })
    }
}
