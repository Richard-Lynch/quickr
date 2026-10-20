import Foundation
import OSLog
import QuickrCore
import QuickrData
import WidgetKit

/// Keeps the Home and Lock Screen widgets in step with the active store, within WidgetKit's reload
/// budget: on any topic or outbox change (a log, an edit, a sync, a server switch) it reads what the
/// widgets show and reloads their timelines only when that changed (`WidgetFingerprint`). Changes
/// that come in a burst (a sync applying many rows) are read once, `settle` after the last.
@MainActor
final class WidgetReloader {
    private var gate = WidgetReloadGate()
    private let reload: () -> Void
    private let settle: Duration
    private var pending: Task<Void, Never>?

    init(settle: Duration = .seconds(1), reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.settle = settle
        self.reload = reload
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
            let fingerprint = WidgetFingerprint(try await reader.dueList(now: Date()))
            guard !Task.isCancelled, gate.shouldReload(fingerprint) else { return }
            reload()
        } catch {
            WidgetReloader.log.error("widget state unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "widgets")
}
