import Observation
import QuickrData
import QuickrUI
import SwiftUI

/// Settings ▸ "Reset local data" (sync-protocol.md §12.1): fetch the warning, confirm once with
/// nothing pending, or twice (the second destructive, naming the loss) when changes would be lost;
/// reset, report.
@MainActor @Observable
final class ResetFlow {
    enum State: Equatable {
        case idle
        case loading
        case confirm(SyncCoordinator.ResetWarning)
        /// The second confirmation, when `count > 0`.
        case confirmLoss(SyncCoordinator.ResetWarning)
        case resetting
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    func begin() async {
        state = .loading
        do {
            guard let warning = try await session.coordinator.resetWarning() else {
                state = .failed("There’s no server to reset yet.")
                return
            }
            state = .confirm(warning)
        } catch {
            state = .failed("Couldn’t check what would be lost: \(error)")
        }
    }

    func cancel() {
        state = .idle
    }

    /// The first confirmation: resets with nothing pending, otherwise asks again. The state
    /// changes before this returns, so the dialog's dismissal sees it.
    func confirmed() {
        guard case .confirm(let warning) = state else { return }
        if warning.needsDestructiveConfirmation {
            state = .confirmLoss(warning)
        } else {
            start(warning)
        }
    }

    /// The second confirmation.
    func confirmedLoss() {
        guard case .confirmLoss(let warning) = state else { return }
        start(warning)
    }

    private func start(_ warning: SyncCoordinator.ResetWarning) {
        state = .resetting
        Task { await perform(warning) }
    }

    private func perform(_ warning: SyncCoordinator.ResetWarning) async {
        do {
            switch try await session.coordinator.performReset(confirmed: warning) {
            case .completed:
                state = .done("Done. Everything was reloaded from the server.")
            case .writesArrived(let newer):
                // Something was logged since the warning: confirm again with the new numbers.
                state = .confirm(newer)
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
    static func message(for warning: SyncCoordinator.ResetWarning) -> String {
        let reload = "quickR deletes its copy on this iPhone and loads everything again from the server."
        guard warning.needsDestructiveConfirmation else { return reload + " Nothing is lost." }
        let changes = warning.count == 1 ? "1 change hasn’t" : "\(warning.count) changes haven’t"
        return reload + " \(changes) synced yet."
    }

    /// The second confirmation's text: what is lost.
    static func lossMessage(for warning: SyncCoordinator.ResetWarning) -> String {
        let changes = warning.count == 1 ? "1 change that hasn’t" : "\(warning.count) changes that haven’t"
        let failed = warning.failedCount > 0 ? " (\(warning.failedCount) of them failed to sync)" : ""
        return "This deletes \(changes) synced\(failed). They can’t be recovered."
    }

    static func lossLabel(for warning: SyncCoordinator.ResetWarning) -> String {
        warning.count == 1 ? "Delete 1 change and reset" : "Delete \(warning.count) changes and reset"
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
                    if flow.state == .loading || flow.state == .resetting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(flow.state == .loading || flow.state == .resetting)
            .accessibilityIdentifier("settings.reset")
            switch flow.state {
            case .done(let message):
                Text(message).foregroundStyle(QuickrTone.ok.foreground).accessibilityIdentifier("settings.resetDone")
            case .failed(let message):
                Text(message).foregroundStyle(QuickrTone.danger.foreground)
            default:
                EmptyView()
            }
        } header: {
            Text("Local data")
        } footer: {
            Text("Reloads this server’s data from scratch. Other servers’ data and the token stay.")
        }
        .confirmationDialog(
            "Reset local data?", isPresented: presented(first.map(ResetFlow.State.confirm)), titleVisibility: .visible,
            presenting: first
        ) { warning in
            Button(warning.needsDestructiveConfirmation ? "Continue…" : "Reset", role: .destructive) {
                flow.confirmed()
            }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { warning in
            Text(ResetFlow.message(for: warning))
        }
        .confirmationDialog(
            "Delete unsynced changes?", isPresented: presented(second.map(ResetFlow.State.confirmLoss)),
            titleVisibility: .visible, presenting: second
        ) { warning in
            Button(ResetFlow.lossLabel(for: warning), role: .destructive) { flow.confirmedLoss() }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { warning in
            Text(ResetFlow.lossMessage(for: warning))
        }
    }

    private var first: SyncCoordinator.ResetWarning? {
        if case .confirm(let warning) = flow.state { return warning }
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
