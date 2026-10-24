import Foundation
import Observation
import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import UIKit

/// The app's services, built once in `QuickRApp.init` and injected with `.environment(_:)`. The
/// composition root is `session` (QuickrData's `AppSession`): store, sync, outbox and the write
/// façade. This type adds what needs UIKit or SwiftUI: settings, navigation, and the scene-phase
/// hooks with their background task.
@MainActor @Observable
final class AppEnvironment {
    let settings: AppSettings
    /// The Cloudflare Access tokens in the Keychain, one per server; the session reads the target
    /// server's on every request.
    let credentials: KeychainAccessCredentials?
    /// A Keychain problem from launch (the legacy token's migration), for Settings to show.
    private(set) var credentialsIssue: String?
    let router = Router()
    /// The sync pill and sheet's state, and the network and timer flush triggers (SYNC-UX).
    let sync: SyncController
    /// Reloads the widgets when what they show changes (WIDGETS).
    let widgets = WidgetReloader()
    /// Every screen's toasts, hosted once at the root so a toast outlives navigation.
    let toasts = ToastCenter()
    /// The §11.4 run notices: toasted while on screen, otherwise listed in the sync sheet.
    let runNotices: RunNoticeCenter
    /// The run surfaces' taps, with their shared cooldown (timers.md §11.1).
    let runActions: RunActions
    /// The one clock behind every running timer on screen.
    let runTicker = RunTicker()
    /// How far above the bottom toasts sit: a screen with a sticky bar (Record's Save) raises them
    /// above it, like the PWA's.
    var toastBottomInset: CGFloat = 8
    /// Numbers typed into tiles but not logged yet (kept while the app runs, like the PWA's).
    let quickLogDrafts = QuickLogDrafts()
    /// Each topic's filters (range, version, source) by its link ref, shared by its Overview and
    /// Entries tabs and kept while the app runs: the PWA keeps them in the page's URL.
    var topicFilters: [String: EntryListFilters] = [:]
    /// Entry writes for tiles and Undo, over `session`.
    let entryWriter = SessionEntryWriter()
    let entryToasts: EntryToasts
    /// Every tile's quick-log model, kept while the app runs (QuickLogModels).
    let quickLogModels: QuickLogModels
    /// A tap-to-fix notification's text, until its record screen takes it (`takeRecordPrefill`).
    var recordPrefill: NotificationPrefill?
    /// Nil only when it couldn't be created (`sessionError`); `start()` tries again.
    private(set) var session: AppSession?
    private(set) var sessionError: String?
    private(set) var lastScenePhase: ScenePhase?
    /// `start()` has finished once: the session has connected to the configured server, or
    /// found there is none. Onboarding waits for it (the session passes `.noServer` on the way).
    private(set) var hasStarted = false

    @ObservationIgnored private let makeSession: @MainActor () throws -> AppSession
    /// APNs registration over the session (notifications.md §9): live builds only. Created on
    /// its first activation (``activatePush()``), which a start cut short by a background expiry
    /// leaves to the next `.active`.
    private(set) var push: PushLifecycle?
    /// Trips to the foreground: one at launch, then one per return from the background (which
    /// passes through `.inactive` on its way to `.active`).
    @ObservationIgnored private var foregroundTrip = 0
    /// `.background` was seen since the last `.active`.
    @ObservationIgnored private var backgroundSinceActive = false
    /// The trip push was last activated in: once per trip, whether the start or `.active` gets
    /// there first.
    @ObservationIgnored private var pushActivatedTrip: Int?
    @ObservationIgnored private let makePush: (@MainActor (AppSession) -> PushLifecycle)?
    @ObservationIgnored private var prepare: (@MainActor () async -> Void)?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// `start()` was cancelled before it finished (see `cancelStart`).
    @ObservationIgnored private var startInterrupted = false

    /// - Parameter prepare: runs once in `start()` before the session opens (a debug demo store's
    ///   seeding); with it, the session opens in `start()` rather than here.
    init(
        settings: AppSettings, credentials: KeychainAccessCredentials? = nil,
        network: any NetworkMonitoring = NWNetworkMonitor(),
        prepare: (@MainActor () async -> Void)? = nil,
        makePush: (@MainActor (AppSession) -> PushLifecycle)? = nil,
        makeSession: @escaping @MainActor () throws -> AppSession
    ) {
        self.settings = settings
        self.credentials = credentials
        self.sync = SyncController(network: network)
        self.makeSession = makeSession
        self.makePush = makePush
        self.prepare = prepare
        entryToasts = EntryToasts(center: toasts, writer: entryWriter)
        let toastCenter = toasts
        runNotices = RunNoticeCenter(toast: { text in
            toastCenter.show(Toast(text, tone: .info, duration: RunNoticeCenter.toastDuration))
        })
        var weakSession: () -> AppSession? = { nil }
        runActions = RunActions(writer: { weakSession().map(RunActions.Writer.init(session:)) })
        quickLogModels = QuickLogModels(writer: entryWriter, toasts: entryToasts, drafts: quickLogDrafts)
        if prepare == nil { openSession() }
        entryWriter.session = { [weak self] in self?.session }
        weakSession = { [weak self] in self?.session }
    }

    /// The live session over the App Group's files, sending through URLSession with the
    /// Cloudflare Access token from the shared Keychain. `categoryCenter` registers the reminder
    /// categories: the app passes the system's; app tests pass nil unless they hold
    /// `SystemCategoriesLock` (the set is one per process, so another suite's session would
    /// replace theirs). No default, so no caller registers with the system by omission.
    /// `notificationCenter` carries GRDB's suspend and resume: `.default` is GRDB's own, so the
    /// app's databases really suspend in the background; a hosted test that backgrounds a session
    /// passes its own, or it would suspend every other suite's database in the process.
    static func live(
        location: StoreLocation = .shared(appGroup: AppGroup.identifier), defaults: UserDefaults = AppGroup.defaults,
        keychain: any KeychainStore = SystemKeychain(), transport: any Transport = URLSessionTransport(),
        network: any NetworkMonitoring = NWNetworkMonitor(),
        categoryCenter: (any NotificationCenterProtocol)?,
        notificationCenter: NotificationCenter = .default
    ) -> AppEnvironment {
        let credentials = KeychainAccessCredentials(keychain: keychain)
        // APNs registration (REG) sends through the same transport and Access token.
        let makePush: @MainActor (AppSession) -> PushLifecycle = {
            PushLifecycle(session: $0, transport: transport, credentials: credentials)
        }
        let makeSession: @MainActor () throws -> AppSession = {
            // Reminder categories go to the system center from launch, ahead of any push (spike F1);
            // registering them needs no notification permission.
            let session = try AppSession(
                configuration: .init(
                    location: location, transport: transport, credentials: credentials,
                    notificationCenter: notificationCenter, categoryCenter: categoryCenter))
            // Addresses resolve to servers through the registry, so each request gets its server's token.
            credentials.directory.attach(session.partitions.registry.repository)
            return session
        }
        return AppEnvironment(
            settings: AppSettings(defaults: defaults), credentials: credentials, network: network, makePush: makePush,
            makeSession: makeSession)
    }

    /// The app's launch path: builds the live environment and registers the active store's topics
    /// for App Intents. Siri, Shortcuts and widget buttons can launch the app for an intent without
    /// a scene, so this runs in `QuickRApp.init`, before anything can query an entity. It opens
    /// the registry only; the store opens on first use. `categoryCenter` as in `live` (app tests
    /// pass nil unless they hold `SystemCategoriesLock`).
    static func bootstrap(
        location: StoreLocation = .shared(appGroup: AppGroup.identifier),
        categoryCenter: (any NotificationCenterProtocol)? = SystemNotificationCenter()
    ) -> AppEnvironment {
        #if DEBUG
        // A probe launch (DeviceProbeLaunch) holds the app's category registrations back while it runs.
        let environment =
            UITestLaunch.isActive
            ? UITestLaunch.environment()
            : DeviceProbeLaunch.requested() != nil
                ? live(location: location, categoryCenter: DeviceProbeLaunch.gatedCenter())
                : live(location: location, categoryCenter: categoryCenter)
        #else
        let environment = live(location: location, categoryCenter: categoryCenter)
        #endif
        environment.registerIntentTopics()
        return environment
    }

    /// What the App Intents queries and the screens read topics from: the active store's.
    var topics: any TopicRepository { session?.topics ?? NoTopicRepository() }

    func registerIntentTopics() {
        IntentTopicSource.register(topics)
        // Writes from Siri, Shortcuts and the Action button (origin `.siri`). An intent can launch
        // the app with no scene, before `start()` binds the session, so the active store is opened
        // through the partitions (with its recovery); the flush is asked of the bound scheduler,
        // when there is one (otherwise the entry goes at the next sync).
        // The session is read when an intent runs (a demo store opens it in `start()`).
        let current: @Sendable () async -> AppSession? = { [weak self] in await MainActor.run { self?.session } }
        IntentWrites.register(
            IntentWriteContext(
                origin: .siri,
                openActiveStore: { try await current()?.partitions.openActiveStore(role: .app)?.store },
                afterCommit: { _ in await current()?.scheduler?.requestFlush(reason: .enqueue) },
                // The app may be suspended in the background (Siri, the Action button): resumed for the write.
                holdStore: {
                    let hold = await current()?.holdStoreResumed()
                    return { await hold?.release() }
                }))
        // OpenRecordIntent, and repeat-last falling back to the record screen: the same hand-off as
        // a tap-to-fix notification's prefill.
        IntentNavigation.register { [weak self] request in
            guard let self else { return }
            switch request {
            case .record(let topicId, let prefill, let scope):
                // The store the intent read the topic from (§7.5): opened only while it's active.
                let texts = prefill.isEmpty ? nil : prefill
                await openScoped(
                    [.record(TopicLinkRef(id: topicId))], serverId: scope.serverId, storeGen: scope.storeGen,
                    prefill: texts.map {
                        NotificationPrefill(serverId: scope.serverId, topicId: topicId.wireString, texts: $0)
                    })
            }
        }
    }

    /// From the root view's `.task`: starts the session (finishing a bootstrap, or connecting to
    /// the configured server) and refreshes the App Shortcuts' topic parameters. A launch for an
    /// intent alone (no scene) never runs it. Concurrent callers share one attempt.
    func start() async {
        if let starting {
            await starting.value
            return
        }
        let attempt = Task {
            if let prepare {
                self.prepare = nil
                await prepare()
            }
            if session == nil {
                openSession()
                registerIntentTopics()
            }
            #if DEBUG || QUICKR_PERF
            PerfProbe.mark("start: begins")
            #endif
            // Before the first request, so it already carries the migrated token.
            await migrateLegacyToken()
            #if DEBUG || QUICKR_PERF
            PerfProbe.mark("start: token migrated")
            #endif
            await session?.start(serverURL: settings.serverURL)
            #if DEBUG || QUICKR_PERF
            PerfProbe.mark("start: session started (bound)")
            #endif
            if let session { sync.startMonitoring(session) }
            // A background refresh's time ran out mid-start (`cancelStart`): the connect may not
            // have happened, and the session won't redo it; the next activation does.
            if Task.isCancelled { startInterrupted = true }
            hasStarted = true
            // Not after an expiry: the OS took the time back (the next `.active` activates it).
            if !Task.isCancelled { await activatePush() }
            QuickRShortcuts.updateAppShortcutParameters()
            // CSV exports an earlier process left (a killed app's): once per process, never this
            // process's own (start() runs again for background refreshes).
            Task.detached(priority: .background) { EntriesExport().sweep(now: Date()) }
        }
        starting = attempt
        await attempt.value
        starting = nil
    }

    /// Waits for the launch's start to finish, 10 s at most: a link or a notification tap can
    /// arrive before the session has bound its store (a cold launch from a widget).
    func startSettled() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !hasStarted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The `scenePhase` hooks (outbox.md §10, sync-protocol.md §9): on `.active`, resume, rebind,
    /// flush and pull; on `.background`, flush inside a background task whose expiration handler
    /// cancels the flush, then suspend the database (0xDEAD10CC).
    /// The run surfaces' part of `scenePhase`, from the first phase on (`initial: true`): a notice
    /// recorded on screen is toasted, and the run clocks read the time again on return.
    func runScenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            runNotices.didBecomeActive()
            runTicker.refresh()
        case .background:
            runNotices.didEnterBackground()
        default:
            break
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background { backgroundSinceActive = true }
        if phase == .active, backgroundSinceActive {
            foregroundTrip += 1
            backgroundSinceActive = false
        }
        lastScenePhase = phase
        guard let session else { return }
        switch phase {
        case .active:
            sync.didBecomeActive()
            let trip = foregroundTrip
            Task {
                await session.didBecomeActive()
                await finishInterruptedStart(session)
                // Still this trip in the foreground: backgrounded meanwhile (perhaps with the start
                // expiring), there is no push work to do.
                guard lastScenePhase == .active, foregroundTrip == trip else { return }
                await activatePush()
            }
        case .background:
            sync.didEnterBackground()
            BackgroundRefresh.schedule()
            flushInBackground(session)
        default:
            break
        }
    }

    /// A `BGAppRefreshTask` (or the debug stand-in): pull, then send, as a background episode of
    /// its own. The expiration handler is installed first, so it also covers starting the session;
    /// once it fires nothing more starts, and the episode (if one began) is expired, which cancels
    /// the pull and the flush and suspends the database. The app becoming active at any point
    /// wins: no episode is created after it, and a current one stops. The next refresh is
    /// scheduled first.
    func backgroundRefresh(_ task: any BackgroundRefreshTask) async {
        BackgroundRefresh.schedule()
        let run = RefreshRun()
        task.onExpiration {
            Task { @MainActor [weak self] in
                let episode = run.expire()
                await self?.stopBackgroundWork(episode)
                task.complete(success: false)
            }
        }
        guard lastScenePhase != .active else {
            task.complete(success: true)
            return
        }
        await start()
        // Startup may have taken a while: expired, or the app was opened meanwhile.
        guard !run.expired else { return }
        guard lastScenePhase != .active, let session else {
            task.complete(success: session != nil)
            return
        }
        let episode = session.beginBackground()
        guard run.begin(episode) else {
            // Expired between the checks: its handler had no episode to stop, so stop this one.
            await session.backgroundTimeExpiring(episode, within: .seconds(2))
            return
        }
        let result = await session.backgroundRefresh(episode)
        task.complete(success: result == .synced && !run.expired)
    }

    /// A refresh's time ran out: stop the session's start where it is, and, in the background,
    /// expire an episode (the refresh's, or a new one if it hadn't begun): that pauses sync and the
    /// outbox, cancels the pull and the flush in flight, and suspends the database. Nothing of
    /// the refresh writes or sends after it.
    /// The app being open owns the start by then: it is never cancelled from the foreground.
    private func stopBackgroundWork(_ episode: AppSession.BackgroundEpisode?) async {
        guard lastScenePhase != .active else { return }
        cancelStart()
        guard let session else { return }
        await session.backgroundTimeExpiring(episode ?? session.beginBackground(), within: .seconds(2))
    }

    private func flushInBackground(_ session: AppSession) {
        // The episode is taken before the expiration handler is registered, so this task's
        // callbacks only ever act on their own trip to the background.
        let episode = session.beginBackground()
        let task = BackgroundTask()
        // On expiry: cancel the flush and wait (briefly) for it and any pull to end before GRDB is
        // suspended; the task ends after that.
        task.begin(name: "quickr.flush") { await session.backgroundTimeExpiring(episode) }
        Task {
            await session.didEnterBackground(episode)
            task.end()
        }
    }

    /// Stops `start()` where it is (a background refresh's time ran out): its requests are
    /// cancelled and it does no more work.
    func cancelStart() {
        starting?.cancel()
    }

    /// Creates push on first use and activates it, once per trip to the foreground: a cold
    /// activation (§9.2) when just created, else a warm one.
    private func activatePush() async {
        guard let session, let makePush, pushActivatedTrip != foregroundTrip else { return }
        pushActivatedTrip = foregroundTrip
        let created = push == nil
        if created { push = makePush(session) }
        await push?.activated(coldLaunch: created)
    }

    /// The connect an expired background start didn't finish, once the app is active.
    private func finishInterruptedStart(_ session: AppSession) async {
        // A start cancelled in the background may still be unwinding: it marks itself interrupted
        // when it ends, so wait for it before looking.
        if let starting { await starting.value }
        guard startInterrupted, lastScenePhase == .active else { return }
        startInterrupted = false
        if session.phase == .noServer, let url = settings.serverURL { await session.connect(baseURL: url) }
    }

    /// The first SETTINGS build kept one token for every server: it becomes the active server's
    /// (the registry's active one, or the configured address before any store exists).
    private func migrateLegacyToken() async {
        guard let credentials, let session else { return }
        do {
            let active = try await session.partitions.registry.repository.activeServerId()
            try credentials.migrateLegacy(serverId: active, baseURL: settings.serverURL)
        } catch {
            credentialsIssue = "Couldn’t move the Cloudflare Access token to this server’s: \(error)"
        }
    }

    private func openSession() {
        do {
            session = try makeSession()
            sessionError = nil
        } catch {
            sessionError = String(describing: error)
        }
    }
}

/// One `beginBackgroundTask`, ended once: by the work, or after the expiration handler's
/// `expiring` has finished.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(name: String, expiring: @escaping @MainActor () async -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                await expiring()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// One background refresh's state, shared with its expiration handler (both on the main actor).
@MainActor
private final class RefreshRun {
    private(set) var expired = false
    private var episode: AppSession.BackgroundEpisode?

    /// Records the episode; false if the run already expired.
    func begin(_ episode: AppSession.BackgroundEpisode) -> Bool {
        guard !expired else { return false }
        self.episode = episode
        return true
    }

    /// Marks the run expired and returns its episode, if one began.
    func expire() -> AppSession.BackgroundEpisode? {
        expired = true
        return episode
    }
}
