import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#endif

public enum ToastTone: Sendable {
    case ok
    case info
    case danger
}

/// A transient message at the bottom of the screen, optionally with one action (usually Undo).
public struct Toast: Sendable {
    public struct Action: Sendable {
        public var label: String
        public var perform: @MainActor @Sendable () -> Void

        public init(_ label: String, perform: @escaping @MainActor @Sendable () -> Void) {
            self.label = label
            self.perform = perform
        }
    }

    public var title: String
    public var message: String?
    public var tone: ToastTone
    public var action: Action?
    /// nil picks the default (``Toast/duration``); `.zero` keeps it until dismissed.
    public var customDuration: Duration?

    public init(
        _ title: String, message: String? = nil, tone: ToastTone = .ok, action: Action? = nil,
        duration: Duration? = nil
    ) {
        self.title = title
        self.message = message
        self.tone = tone
        self.action = action
        self.customDuration = duration
    }

    /// Undo toasts stay 6 s so there is time to reach the button; plain ones 3.5 s.
    public static let actionDuration: Duration = .seconds(6)
    public static let plainDuration: Duration = .milliseconds(3500)

    /// How long it stays up, or nil when it stays until dismissed.
    public var duration: Duration? {
        let d = customDuration ?? (action == nil ? Self.plainDuration : Self.actionDuration)
        return d > .zero ? d : nil
    }

    /// ``duration`` while VoiceOver runs: a toast with an action or an error stays until it's
    /// dismissed or acted on, since VoiceOver reaches the toast last and the time can't be
    /// adjusted otherwise (WCAG 2.2.1). Plain notices still go, after being announced.
    public var durationUnderVoiceOver: Duration? {
        action != nil || tone == .danger ? nil : duration
    }

    /// What VoiceOver announces when it appears: the title, the message, and how to reach the
    /// action (a two-finger double-tap runs it; see `ToastCenter.performNewestAction`).
    public var announcement: String {
        var parts = [title]
        if let message { parts.append(message) }
        if let action { parts.append("\(action.label) available: double-tap with two fingers") }
        return parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }
}

/// The visible stack: newest last, at most ``maxVisible``; a new toast pushes out the oldest.
public struct ToastStack: Sendable {
    public struct Item: Identifiable, Sendable {
        public let id: Int
        public let toast: Toast
    }

    public static let maxVisible = 3

    public private(set) var items: [Item] = []
    private var nextID = 1

    public init() {}

    @discardableResult
    public mutating func push(_ toast: Toast) -> Int {
        let id = nextID
        nextID += 1
        items.append(Item(id: id, toast: toast))
        if items.count > Self.maxVisible { items.removeFirst(items.count - Self.maxVisible) }
        return id
    }

    public mutating func dismiss(_ id: Int) {
        items.removeAll { $0.id == id }
    }
}

/// Owns the toast stack for a screen tree and dismisses each toast when its time is up.
/// Show it with `.toastHost(_:)`; post with ``show(_:)``.
@MainActor @Observable
public final class ToastCenter {
    public private(set) var stack = ToastStack()
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let voiceOverRunning: @MainActor () -> Bool
    @ObservationIgnored private var timers: [Int: Task<Void, Never>] = [:]
    /// Each timer's generation: a timer whose sleep finished just as it was replaced (VoiceOver
    /// turned on) finds a newer generation and leaves the toast alone.
    @ObservationIgnored private var generations: [Int: Int] = [:]
    @ObservationIgnored private var nextGeneration = 0

    /// `sleep` and `voiceOverRunning` are injectable so tests can run the timers without waiting
    /// and without VoiceOver.
    public init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        voiceOverRunning: @escaping @MainActor () -> Bool = ToastCenter.systemVoiceOverRunning
    ) {
        self.sleep = sleep
        self.voiceOverRunning = voiceOverRunning
    }

    /// `UIAccessibility.isVoiceOverRunning` (false where there is no UIKit).
    public static func systemVoiceOverRunning() -> Bool {
        #if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning
        #else
        false
        #endif
    }

    public var items: [ToastStack.Item] { stack.items }

    @discardableResult
    public func show(_ toast: Toast) -> Int {
        let id = stack.push(toast)
        for gone in timers.keys where !stack.items.contains(where: { $0.id == gone }) {
            timers.removeValue(forKey: gone)?.cancel()
        }
        schedule(id, toast)
        return id
    }

    /// VoiceOver was turned on or off (`UIAccessibility.voiceOverStatusDidChangeNotification`;
    /// `.toastHost` calls it): every visible toast restarts its timer under the new rule, so
    /// turning VoiceOver on keeps the actionable ones, and turning it off lets them go again.
    public func voiceOverStatusChanged() {
        for item in stack.items { schedule(item.id, item.toast) }
    }

    /// The magic tap (a two-finger double-tap anywhere): runs the newest toast's action, if any
    /// toast has one. Returns whether it ran one, so the caller can let the system's own magic tap
    /// (play/pause) through when it didn't. The app calls it from its delegate's
    /// `accessibilityPerformMagicTap()`, the end of the responder chain: a SwiftUI
    /// `.accessibilityAction(.magicTap)` can't decline, and would swallow the system's.
    @discardableResult
    public func performNewestAction() -> Bool {
        guard let item = stack.items.last(where: { $0.toast.action != nil }) else { return false }
        performAction(item.id)
        return true
    }

    private func schedule(_ id: Int, _ toast: Toast) {
        timers.removeValue(forKey: id)?.cancel()
        nextGeneration += 1
        let generation = nextGeneration
        generations[id] = generation
        guard let duration = voiceOverRunning() ? toast.durationUnderVoiceOver : toast.duration else { return }
        let sleep = self.sleep
        timers[id] = Task { [weak self] in
            do { try await sleep(duration) } catch { return }
            self?.timerFired(id, generation: generation)
        }
    }

    private func timerFired(_ id: Int, generation: Int) {
        guard generations[id] == generation else { return }
        dismiss(id)
    }

    public func dismiss(_ id: Int) {
        timers.removeValue(forKey: id)?.cancel()
        generations.removeValue(forKey: id)
        stack.dismiss(id)
    }

    /// Runs the toast's action, then dismisses it.
    public func performAction(_ id: Int) {
        guard let item = stack.items.first(where: { $0.id == id }) else { return }
        dismiss(id)
        item.toast.action?.perform()
    }
}
