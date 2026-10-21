import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The header's sync pill (HOME's toolbar): hidden when all is synced, otherwise the
/// `SyncPillState` in the design system's `SyncPill`. Tapping opens the sync sheet (`syncSheet`,
/// on the root).
struct SyncPillButton: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let state = environment.sync.pill(status: environment.session?.syncStatus ?? DataSyncStatus())
        SyncPill(state.design) { environment.sync.isSheetPresented = true }
            .accessibilityIdentifier("sync.pill")
    }
}

extension View {
    /// The sync sheet, presented from the root (`SyncController.isSheetPresented`). Its Fix
    /// closes it and opens RECORD's fix mode.
    func syncSheet(_ environment: AppEnvironment) -> some View {
        @Bindable var sync = environment.sync
        return sheet(isPresented: $sync.isSheetPresented) {
            SyncSheet { route in
                sync.isSheetPresented = false
                environment.router.open(route)
            }
            .environment(environment)
        }
    }
}

extension SyncPillState {
    /// The design system's pill for this state; nil hides it.
    var design: DesignSyncStatus? {
        let kind: DesignSyncStatus.Kind
        switch self {
        case .hidden: return nil
        case .failed: kind = .failed
        case .offline: kind = .offline
        case .waiting: kind = .waiting
        case .differentServer, .syncError: kind = .attention
        case .loadingHistory: kind = .loading
        }
        return DesignSyncStatus(kind: kind, short: shortLabel, label: label, accessibilityLabel: accessibilityLabel)
    }
}
