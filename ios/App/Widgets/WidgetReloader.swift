import Foundation
import OSLog
import QuickrCore
import QuickrData
import WidgetKit

/// Keeps the Home and Lock Screen widgets and the Controls in step with the active store, within
/// WidgetKit's reload budget: on any topic or outbox change (a log, an edit, a sync, a server switch) it reads what the
/// widgets show and reloads their timelines only when that changed (`WidgetFingerprint`). Changes
/// that come in a burst (a sync applying many rows) are read once, `settle` after the last.
@MainActor
final class WidgetReloader {
    private var timelines = WidgetReloadGate<WidgetFingerprint>()
    private var controls = WidgetReloadGate<ControlFingerprint>()
    private let reloadTimelines: () -> Void
    private let reloadControls: () -> Void
    private let settle: Duration
    private var pending: Task<Void, Never>?

    /// Timelines and Controls reload separately, each only when what it shows changed.
    init(
        settle: Duration = .seconds(1),
        reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        reloadControls: @escaping () -> Void = { ControlCenter.shared.reloadAllControls() }
    ) {
        self.settle = settle
        self.reloadTimelines = reloadTimelines
        self.reloadControls = reloadControls
    }

    /// Follows `store` until it closes or the task is cancelled (the next binding follows its own).
    func observe(_ store: LocalStore, refresh: AsyncStream<Void>? = nil) async {
        let reader = WidgetReader(store: store)
        async let topics: Void = follow(store.observeTopics(refresh: refresh), reader)
        async let outbox: Void = follow(store.observeOutbox(), reader)
        _ = await (topics, outbox)
        pending?.cancel()
    }

    private func follow<Element>(_ changes: AsyncThrowingStream<Element, any Error>, _ reader: WidgetReader) async {
        do {
            for try await _ in changes { changed(reader) }
        } catch {
            // the store closed (reset, server switch): the next binding follows its own
        }
    }

    private func changed(_ reader: WidgetReader) {
        pending?.cancel()
        pending = Task { [weak self, settle] in
            do { try await Task.sleep(for: settle) } catch { return }
            await self?.check(reader)
        }
    }

    private func check(_ reader: WidgetReader) async {
        do {
            let shown = try await reader.dueList(now: Date())
            guard !Task.isCancelled else { return }
            if timelines.shouldReload(WidgetFingerprint(shown)) { reloadTimelines() }
            if controls.shouldReload(ControlFingerprint(shown)) { reloadControls() }
        } catch {
            WidgetReloader.log.error("widget state unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "widgets")
}
