import Foundation
import Observation

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
    @ObservationIgnored private var timers: [Int: Task<Void, Never>] = [:]

    /// `sleep` is injectable so tests can run the timers without waiting.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public var items: [ToastStack.Item] { stack.items }

    @discardableResult
    public func show(_ toast: Toast) -> Int {
        let id = stack.push(toast)
        for gone in timers.keys where !stack.items.contains(where: { $0.id == gone }) {
            timers.removeValue(forKey: gone)?.cancel()
        }
        if let duration = toast.duration {
            let sleep = self.sleep
            timers[id] = Task { [weak self] in
                do { try await sleep(duration) } catch { return }
                self?.dismiss(id)
            }
        }
        return id
    }

    public func dismiss(_ id: Int) {
        timers.removeValue(forKey: id)?.cancel()
        stack.dismiss(id)
    }

    /// Runs the toast's action, then dismisses it.
    public func performAction(_ id: Int) {
        guard let item = stack.items.first(where: { $0.id == id }) else { return }
        dismiss(id)
        item.toast.action?.perform()
    }
}
