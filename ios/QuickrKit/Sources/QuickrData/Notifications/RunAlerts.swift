#if canImport(UserNotifications)
import UserNotifications

/// Run alerts (timers2.md §9.1): the lap/step alerts of an open run, delivered as local
/// notifications. I1-ALERTS adds the planner (`RunAlertPlan`) and the scheduler here; this file
/// holds the one constant they read, so the OQ-6 fallback is a single-line change.
public enum RunAlerts {
    /// timers2.md §9.1 / OQ-6 rider: `.timeSensitive` needs the entitlement in `ios/project.yml`
    /// (T2-M1 block) and the capability on the App ID; flip to `.active` if `v0.4.0-rc1` fails to sign.
    public static let interruptionLevel: UNNotificationInterruptionLevel = .timeSensitive
}
#endif
