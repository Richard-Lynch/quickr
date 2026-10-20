#if os(iOS)
import SwiftUI

/// The header's sync pill: "Offline", "3" (waiting) or "2 failed". Hidden when all is synced.
/// Tapping opens the sync sheet (the caller's `action`).
public struct SyncPill: View {
    let status: SyncStatus?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ status: SyncStatus?, action: @escaping () -> Void) {
        self.status = status
        self.action = action
    }

    public init(online: Bool, pending: Int, failed: Int, action: @escaping () -> Void) {
        self.init(SyncStatus(online: online, pending: pending, failed: failed), action: action)
    }

    public var body: some View {
        if let status {
            Button(action: action) {
                HStack(spacing: 6) {
                    icon(status)
                    Text(status.short).lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.qr(.caption))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .foregroundStyle(foreground(status.kind))
                .background(background(status.kind), in: Capsule())
                // 32 pt to look at, 44 pt to tap.
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuickrPressStyle())
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityHint("Shows what is waiting to sync")
        }
    }

    @ViewBuilder
    private func icon(_ status: SyncStatus) -> some View {
        switch status.kind {
        case .failed: QIcon.alert.view(size: 16)
        case .offline: QIcon.cloudOff.view(size: 16)
        case .waiting:
            QIcon.sync.view(size: 16)
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(0.4), isActive: !reduceMotion)
        }
    }

    private func foreground(_ kind: SyncStatus.Kind) -> Color {
        switch kind {
        case .failed: .white
        case .offline: .qr.warn
        case .waiting: .qr.info
        }
    }

    private func background(_ kind: SyncStatus.Kind) -> Color {
        switch kind {
        case .failed: .qr.danger
        case .offline: .qr.warnSoft
        case .waiting: .qr.infoSoft
        }
    }
}

#Preview("Sync pill") {
    HStack {
        SyncPill(online: false, pending: 0, failed: 0) {}
        SyncPill(online: true, pending: 3, failed: 0) {}
        SyncPill(online: true, pending: 1, failed: 2) {}
    }
    .padding()
    .background(Color.qr.paper)
}
#endif
