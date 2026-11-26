import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// R8 (timers.md §10.3, §13.3): Live Activity reconciliation with a fake activity centre. Ends
/// orphaned and duplicate activities; updates one whose content differs from the view; starts one
/// only for this device's own start; T-LAPUSH L8's finishing and discarded runs; the Settings
/// switch; token registration.
@Suite(.timeLimit(.minutes(5))) @MainActor struct LiveActivityReconcileTests {
    nonisolated static let now = Make.t0.addingTimeInterval(600)

    /// A harness with a timed topic, a fake centre, fake token endpoints and the controller over
    /// them. The push-to-start token is "start01", as `pushToStartTokenUpdates` hands it at launch.
    @MainActor struct Rig {
        let h: OutboxHarness
        let center = FakeActivityCenter()
        let api: FakeTokenAPI
        let tokens: LiveActivityTokens
        let activities: LiveActivities

        /// `api` is shared across "launches" (its server and owed deletes persist).
        static func make(requiresAnswers: Bool = false, api: FakeTokenAPI = FakeTokenAPI(), pushToStart: Bool = true)
            async throws -> Rig
        {
            let rig = try Rig(requiresAnswers: requiresAnswers, api: api)
            if pushToStart { await rig.tokens.pushToStart("start01") }
            return rig
        }

        private init(requiresAnswers: Bool, api: FakeTokenAPI) throws {
            let h = try OutboxHarness()
            try h.timed(requiresAnswers: requiresAnswers)
            self.h = h
            self.api = api
            tokens = LiveActivityTokens(
                .init(
                    register: { try await api.register($0) }, unregister: { try api.unregister($0) },
                    deviceToken: { "dev1" }, environment: { .sandbox }, serverId: { api.serverId },
                    loadOwed: { api.owed }, saveOwed: { api.owed = $0 }))
            let store = h.store
            activities = LiveActivities(
                center: center, tokens: tokens, enabled: true,
                snapshot: { (try? await RunActivitySnapshot.read(store)) ?? nil },
                now: { LiveActivityReconcileTests.now })
        }

        /// Waits for the token work (it runs beside the activity work).
        func settle() async { await activities.tokensSettled() }

        /// An activity's update token arrives (`pushTokenUpdates`).
        func token(_ token: String, for activityId: String) async {
            await tokens.update(token, activityId: activityId)
        }

        var attributes: RunActivityAttributes {
            RunActivityContent.attributes(serverId: "server-1", topicId: h.topic.id, topicName: h.topic.name)
        }

        /// The view's content state for the run `id` routes to.
        func viewState(_ id: String) throws -> RunActivityState {
            let run = try #require(try h.localRun(id))
            return try #require(RunActivitySnapshot.state(run))
        }
    }

    // MARK: - Start

    @Test("R8 · this device's start requests one activity, with the view's content and a 4 h stale date")
    func startRequestsOne() async throws {
        let rig = try await Rig.make()
        let runId = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let all = await rig.center.all()
        #expect(all.count == 1)
        let activity = try #require(all.first)
        #expect(activity.attributes == rig.attributes)
        let expected = try rig.viewState(runId)
        #expect(activity.state == expected)
        #expect(activity.state.label == "Shower")
        let staleDate: Date? = activity.staleDate
        #expect(staleDate == Self.now.addingTimeInterval(4 * 3600))
    }

    @Test("R8 · reconciliation alone never starts one: a run started elsewhere comes by push-to-start")
    func noStartWithoutTap() async throws {
        let rig = try await Rig.make()
        try rig.h.seedServerRun()
        await rig.activities.reconcile()
        let all = await rig.center.all()
        #expect(all.isEmpty)
    }

    @Test("R8 · iOS refusing a request leaves the run without one")
    func refusedRequest() async throws {
        let rig = try await Rig.make()
        await rig.center.refuse()
        _ = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let all = await rig.center.all()
        #expect(all.isEmpty)
    }

    // MARK: - Lap types and alerts (I2-LA-FIELDS)

    @Test("I2-LA-FIELDS · the snapshot carries the pinned timer: lap type, next lap type and the alert")
    func lapTypesAndAlertFromThePinnedTimer() async throws {
        let rig = try await Rig.make()
        try rig.h.lapTyped()
        let runId = try await rig.h.runs().start(topic: rig.h.ref, version: 2).runId
        rig.h.wall.advance(by: 60)
        _ = try await rig.h.runs().lap(runId: runId)
        let snapshot = try #require(try await RunActivitySnapshot.read(rig.h.store))
        let timer: TopicTimer? = snapshot.timers[runId]
        #expect(timer?.laps.map(\.key) == ["run", "rest"])
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let activity = try #require(await rig.center.all().first)
        let state = activity.state
        #expect(state.label == "Rest 1")
        let lapType: String? = state.lapType
        #expect(lapType == "rest")
        let lapCount: Int? = state.lapCount
        #expect(lapCount == 1)
        let nextLabel: String? = state.nextLabel
        #expect(nextLabel == "Run")
        // Rest from 60 s, "Go" 15 minutes in; `now` is 600 s.
        let alertAt: Double? = state.alertAt
        #expect(alertAt == Make.t0.timeIntervalSince1970 + 960)
        let alertLabel: String? = state.alertLabel
        #expect(alertLabel == "Go")
        let display = RunActivityDisplay(state: state, topicName: rig.h.topic.name)
        #expect(display.headline == "Rest 1 · lap 2")
        let lapCounter: String? = display.lapCounter
        #expect(lapCounter == "L2")
        #expect(display.title(for: .lap) == "Lap → Run")
        // The same view again: nothing to do.
        await rig.activities.reconcile()
        let updates = await rig.center.updates
        #expect(updates == 0)
    }

    /// M2-RESUME: this device's own tap updates its activity through `reconcile(after:)` (R20, the
    /// app's tap writer) with the pinned timer's fields, so a local update never blanks what the
    /// server pushed: the lap type and count, the next lap type and the alert.
    @Test("A local tap's update keeps the lap and alert fields (reconcile(after:), the timer:now: state)")
    func aLocalTapsUpdateKeepsTheLapAndAlertFields() async throws {
        let rig = try await Rig.make()
        try rig.h.lapTyped()
        let runId = try await rig.h.runs().start(topic: rig.h.ref, version: 2).runId
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let started = try #require(await rig.center.all().first).state
        let startedType: String? = started.lapType
        #expect(startedType == "run")
        rig.h.wall.advance(by: 60)
        let result = try await rig.h.runs().lap(runId: runId)
        await rig.activities.reconcile(after: result)
        let updates = await rig.center.updates
        #expect(updates == 1, "the tap updated the activity it had")
        let state = try #require(await rig.center.all().first).state
        #expect(state.label == "Rest 1")
        let lapType: String? = state.lapType
        #expect(lapType == "rest")
        let lapCount: Int? = state.lapCount
        #expect(lapCount == 1)
        let nextLabel: String? = state.nextLabel
        #expect(nextLabel == "Run")
        let alertAt: Double? = state.alertAt
        #expect(alertAt == Make.t0.timeIntervalSince1970 + 960, "Rest from 60 s, Go 15 minutes in")
        let alertLabel: String? = state.alertLabel
        #expect(alertLabel == "Go")
    }

    @Test("I2-LA-FIELDS · a pause drops the alert from the activity, and a resume brings it back")
    func pauseDropsTheAlert() async throws {
        let rig = try await Rig.make()
        try rig.h.lapTyped()
        let runId = try await rig.h.runs().start(topic: rig.h.ref, version: 2).runId
        rig.h.wall.advance(by: 60)
        _ = try await rig.h.runs().lap(runId: runId)
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        rig.h.wall.advance(by: 30)
        _ = try await rig.h.runs().pause(runId: runId)
        await rig.activities.reconcile()
        let paused = try #require(await rig.center.all().first).state
        #expect(paused.status == "paused")
        let pausedAlert: Double? = paused.alertAt
        #expect(pausedAlert == nil)
        let lapType: String? = paused.lapType
        #expect(lapType == "rest")
        rig.h.wall.advance(by: 30)
        _ = try await rig.h.runs().resume(runId: runId)
        await rig.activities.reconcile()
        let resumed = try #require(await rig.center.all().first).state
        // 30 s paused inside the rest: "Go" moves 30 s later.
        let resumedAlert: Double? = resumed.alertAt
        #expect(resumedAlert == Make.t0.timeIntervalSince1970 + 990)
        let updates = await rig.center.updates
        #expect(updates == 2)
    }

    /// `alert_at` is anchored to the segment's start and pauses, so the passing of time alone
    /// changes the content state only when an alert passes: then the next one (by `at_ms`) is
    /// shown, and after the last none. One update per alert passed, none in between.
    @Test("I2-LA-FIELDS · time alone updates the activity only as each alert passes")
    func alertBoundaries() async throws {
        let rig = try await Rig.make()
        try rig.h.lapTyped()
        let runId = try await rig.h.runs().start(topic: rig.h.ref, version: 2).runId
        rig.h.wall.advance(by: 60)
        _ = try await rig.h.runs().lap(runId: runId)
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let record = try #require(await rig.center.activities().first)
        let snapshot = try #require(try await RunActivitySnapshot.read(rig.h.store))
        // Rest opened at 60 s; its one alert ("Go", 15 min) fires at 960 s.
        let t0 = Make.t0.timeIntervalSince1970
        #expect(record.state.alertAt == t0 + 960)
        for s in [600.0, 700, 959] {
            let actions = RunActivityPlan.actions([record], snapshot, now: Make.t0.addingTimeInterval(s))
            #expect(actions.isEmpty, "\(s) s")
        }
        let past = RunActivityPlan.actions([record], snapshot, now: Make.t0.addingTimeInterval(961))
        guard case .update(_, let state)? = past.first, past.count == 1 else {
            Issue.record("expected one update, got \(past)")
            return
        }
        let alertAt: Double? = state.alertAt
        #expect(alertAt == nil)
        let alertLabel: String? = state.alertLabel
        #expect(alertLabel == nil)
        #expect(state.lapType == "rest")
    }

    /// Two alerts: the earlier by `at_ms` first, whatever their order in the timer, then the
    /// later once it passes.
    @Test("I2-LA-FIELDS · with several alerts the next by at_ms is shown, then the one after")
    func severalAlertsInOrder() async throws {
        let rig = try await Rig.make()
        let timer = TopicTimer(
            steps: [],
            laps: [
                TopicTimer.LapType(
                    key: "run", label: "Run",
                    alerts: [
                        TopicTimer.Alert(key: "time", label: "Time", at: "10m", atMs: 600_000),
                        TopicTimer.Alert(key: "half", label: "Half way", at: "5m", atMs: 300_000),
                    ])
            ])
        let row = TopicVersion(version: 2, questions: [], timer: timer, createdAt: Make.t0)
        let topicId = rig.h.topic.id
        try rig.h.write { db in _ = try ServerLayer.insert(db, version: row, id: UUID(), topicId: topicId) }
        _ = try await rig.h.runs().start(topic: rig.h.ref, version: 2)
        let snapshot = try #require(try await RunActivitySnapshot.read(rig.h.store))
        let run = try #require(snapshot.runs.first)
        let t0 = Make.t0.timeIntervalSince1970
        let early = try #require(snapshot.state(run, now: Make.t0.addingTimeInterval(10)))
        #expect(early.alertAt == t0 + 300)
        #expect(early.alertLabel == "Half way")
        let later = try #require(snapshot.state(run, now: Make.t0.addingTimeInterval(301)))
        #expect(later.alertAt == t0 + 600)
        #expect(later.alertLabel == "Time")
        let none = try #require(snapshot.state(run, now: Make.t0.addingTimeInterval(601)))
        let noneAt: Double? = none.alertAt
        #expect(noneAt == nil)
    }

    // MARK: - Updates

    @Test("R8 · an activity whose content differs from the view is updated to it")
    func updatesWhenDifferent() async throws {
        let rig = try await Rig.make()
        let runId = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        rig.h.wall.advance(by: 60)
        _ = try await rig.h.runs().next(runId: runId)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.state.label == "Breakfast")
        #expect(activity.state.seg == 1)
        let updates = await rig.center.updates
        #expect(updates == 1)
        // Each local update marks it stale 4 hours ahead, as the request did.
        let staleDate: Date? = activity.staleDate
        #expect(staleDate == Self.now.addingTimeInterval(4 * 3600))
        // The same view again: nothing to do.
        await rig.activities.reconcile()
        let again = await rig.center.updates
        #expect(again == 1)
    }

    @Test("R8 · M29: the same content at another revision isn't an update")
    func revisionAloneIsNoUpdate() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        var shown = try rig.viewState(server.id.wireString)
        shown.revision = 0  // a queued tap's local state kept the server's older revision
        await rig.center.seed(rig.attributes, shown, staleDate: Self.now)
        await rig.activities.reconcile()
        let updates = await rig.center.updates
        #expect(updates == 0)
        let a = try rig.viewState(server.id.wireString)
        var b = a
        b.revision += 5
        #expect(a.showsSame(as: b))
        b.seg += 1
        #expect(!a.showsSame(as: b))
    }

    @Test("R8 · a push ahead of this device's view isn't reverted")
    func pushAheadIsKept() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        let runId = server.id.wireString
        // The server pushed revision 3 (another device's Next); this device holds revision 1.
        var pushed = try rig.viewState(runId)
        pushed.revision = 3
        pushed.seg = 1
        pushed.label = "Breakfast"
        await rig.center.seed(rig.attributes, pushed, staleDate: Self.now)
        await rig.activities.reconcile()
        let updates = await rig.center.updates
        #expect(updates == 0)
        // Once this device taps, its view folds over it and wins.
        _ = try await rig.h.runs().pause(runId: runId)
        await rig.activities.reconcile()
        let after = await rig.center.updates
        #expect(after == 1)
    }

    @Test("R8 · an activity left on another run of the topic follows the open one")
    func followsTheOpenRun() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        var old = try rig.viewState(server.id.wireString)
        old.runId = UUID().wireString
        await rig.center.seed(rig.attributes, old, staleDate: Self.now)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.state.runId == server.id.wireString)
    }

    // MARK: - Ending

    @Test("R8 · an activity whose topic has no run in the view is ended at once")
    func endsOrphans() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        let state = try rig.viewState(server.id.wireString)
        await rig.center.seed(rig.attributes, state, staleDate: Self.now)
        // Stopped elsewhere: the feed deleted the run.
        try rig.h.write { db in
            try ServerLayer.applyDeletion(db, kind: .run, id: server.id, topicId: rig.h.topic.id, seq: nil)
        }
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .ended)
        let dismissal: RunActivityDismissal? = activity.dismissal
        #expect(dismissal == .immediate)
    }

    @Test("R8 · another server's activity is ended")
    func endsOtherServers() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        let state = try rig.viewState(server.id.wireString)
        var attributes = rig.attributes
        attributes.serverId = "server-2"
        await rig.center.seed(attributes, state, staleDate: Self.now)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .ended)
    }

    @Test("R8 · duplicates for one (server, topic) end, keeping the most recently updated")
    func endsDuplicates() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        let state = try rig.viewState(server.id.wireString)
        let older = await rig.center.seed(rig.attributes, state, staleDate: Self.now.addingTimeInterval(-60))
        let newer = await rig.center.seed(rig.attributes, state, staleDate: Self.now)
        let oldest = await rig.center.seed(rig.attributes, state, staleDate: nil)
        await rig.activities.reconcile()
        let all = await rig.center.all()
        let kept = all.filter(\.phase.isLive).map(\.id)
        #expect(kept == [newer])
        let ended = Set(all.filter { $0.phase == .ended }.map(\.id))
        #expect(ended == [older, oldest])
    }

    @Test("R8 · a stop here ends the activity with what was saved, dismissed after 15 minutes")
    func stopEndsSaved() async throws {
        let rig = try await Rig.make()
        let runId = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        rig.h.wall.advance(by: 90)
        _ = try await rig.h.runs().stop(runId: runId)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .ended)
        #expect(activity.state.status == "stopped")
        let activeMs: Int? = activity.state.activeMs
        #expect(activeMs == 90_000)
        let dismissal: RunActivityDismissal? = activity.dismissal
        #expect(dismissal == .after(Self.now.addingTimeInterval(15 * 60)))
        // Acknowledged: the run leaves the view, and the ended activity is left alone.
        _ = try await rig.h.outbox().flushNow()
        await rig.activities.reconcile()
        let ends = await rig.center.ends
        #expect(ends == 1)
    }

    @Test("R8 · L8: a finishing run's activity says Add details, then Saved once finished here")
    func finishingThenFinished() async throws {
        let rig = try await Rig.make(requiresAnswers: true)
        let runId = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        rig.h.wall.advance(by: 60)
        let writes = rig.h.runs()
        _ = try await writes.stop(runId: runId)
        await rig.activities.reconcile()
        let finishing = try #require(await rig.center.all().first)
        #expect(finishing.phase == .ended)
        #expect(finishing.state.status == "finishing")
        let text = RunActivityDisplay(state: finishing.state, topicName: "").endedText
        #expect(text == "Add details")
        // Still finishing: left alone.
        await rig.activities.reconcile()
        let ends = await rig.center.ends
        #expect(ends == 1)

        _ = try await writes.finish(runId: runId, answers: ["mood": .int(4)])
        await rig.activities.reconcile()
        let saved = try #require(await rig.center.all().first)
        #expect(saved.state.status == "stopped")
        let activeMs: Int? = saved.state.activeMs
        #expect(activeMs == 60_000)
        let dismissal: RunActivityDismissal? = saved.dismissal
        #expect(dismissal == .after(Self.now.addingTimeInterval(15 * 60)))
    }

    @Test("R8 · L8: a finishing activity whose run left the view (finished elsewhere) is dismissed")
    func finishingGoneIsDismissed() async throws {
        let rig = try await Rig.make(requiresAnswers: true)
        let server = try rig.h.seedServerRun()
        var state = try rig.viewState(server.id.wireString)
        state.status = "finishing"
        let id = await rig.center.seed(rig.attributes, state, staleDate: Self.now)
        await rig.center.endNow(id)
        try rig.h.write { db in
            try ServerLayer.applyDeletion(db, kind: .run, id: server.id, topicId: rig.h.topic.id, seq: nil)
        }
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        let dismissal: RunActivityDismissal? = activity.dismissal
        #expect(dismissal == .immediate)
    }

    @Test("R8 · a discarded run's activity ends at once")
    func discardEndsAtOnce() async throws {
        let rig = try await Rig.make()
        let runId = try await rig.h.start()
        _ = try await rig.h.outbox().flushNow()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        _ = try await rig.h.runs().discard(runId: runId)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .ended)
        #expect(activity.state.status == "discarded")
        let dismissal: RunActivityDismissal? = activity.dismissal
        #expect(dismissal == .immediate)
    }

    // MARK: - The Settings switch

    @Test("R8 · Settings off ends every activity at once and unregisters the tokens; on registers again")
    func settingsSwitch() async throws {
        let rig = try await Rig.make()
        _ = try await rig.h.start()
        _ = try await rig.h.outbox().flushNow()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let activity = try #require(await rig.center.all().first)
        await rig.token("ab01", for: activity.id)
        await rig.activities.reconcile()
        await rig.activities.setEnabled(false)
        await rig.settle()
        let ended = try #require(await rig.center.all().first)
        #expect(ended.phase == .ended)
        let dismissal: RunActivityDismissal? = ended.dismissal
        #expect(dismissal == .immediate)
        let deleted = Set(rig.api.deleted)
        #expect(deleted == ["ab01", "start01"])
        let shown = await rig.activities.willShowLocally()
        #expect(shown == false)
        // Off: nothing starts.
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let count = await rig.center.all().count
        #expect(count == 1)

        await rig.activities.setEnabled(true)
        await rig.settle()
        let starts = rig.api.registered.filter { $0.kind == .start }.count
        #expect(starts == 2)
    }

    @Test("R8 · M3: off unregisters the push-to-start token even if this launch never registered it")
    func offUnregistersAnUnregisteredStartToken() async throws {
        let rig = try await Rig.make()
        rig.api.serverId = nil  // nothing can be registered this launch
        await rig.activities.setEnabled(false)
        await rig.settle()
        let deleted = rig.api.deleted
        #expect(deleted == ["start01"])
    }

    @Test("R8 · M3: while off, a deleted push-to-start token isn't deleted again at every pass")
    func offDeletesOnce() async throws {
        let rig = try await Rig.make()
        await rig.activities.setEnabled(false)
        await rig.activities.reconcile()
        await rig.activities.tokensChanged()
        await rig.activities.reconcile()
        await rig.settle()
        let deleted = rig.api.deleted
        #expect(deleted == ["start01"])
    }

    @Test("R8 · M3: a delete that fails is kept and retried, across launches")
    func owedDeletesAreDurable() async throws {
        let api = FakeTokenAPI()
        let first = try await Rig.make(api: api)
        api.failingDeletes(true)
        await first.activities.setEnabled(false)
        await first.settle()
        let owed = api.owed
        #expect(owed == ["start01"])
        // The next launch, the switch still off, pays it.
        api.failingDeletes(false)
        let second = try await Rig.make(api: api, pushToStart: false)
        await second.activities.setEnabled(false)
        await second.activities.reconcile()
        await second.settle()
        let deleted = api.deleted
        #expect(deleted == ["start01"])
        let left = api.owed
        #expect(left.isEmpty)
    }

    @Test("R8 · M3: while off, reconciliation ends a live activity (a push-to-start that got through)")
    func offEndsLiveActivities() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        await rig.activities.setEnabled(false)
        let state = try rig.viewState(server.id.wireString)
        await rig.center.seed(rig.attributes, state, staleDate: Self.now)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .ended)
        let dismissal: RunActivityDismissal? = activity.dismissal
        #expect(dismissal == .immediate)
    }

    // MARK: - Tokens

    @Test("R8 · the push-to-start token is registered with this phone's APNs token, once")
    func pushToStartToken() async throws {
        let rig = try await Rig.make()
        await rig.activities.tokensChanged()
        await rig.activities.tokensChanged()
        await rig.settle()
        let starts = rig.api.registered.filter { $0.kind == .start }
        #expect(starts.count == 1)
        let first = try #require(starts.first)
        #expect(first.token == "start01")
        #expect(first.deviceToken == "dev1")
        #expect(first.environment == .sandbox)
    }

    @Test("R8 · M4: the push-to-start token is registered again with a new server")
    func pushToStartFollowsTheServer() async throws {
        let rig = try await Rig.make()
        await rig.activities.tokensChanged()
        await rig.settle()
        rig.api.serverId = "server-2"
        await rig.activities.tokensChanged()
        await rig.settle()
        await rig.activities.tokensChanged()
        await rig.settle()
        let starts = rig.api.registered.filter { $0.kind == .start }.count
        #expect(starts == 2)
    }

    @Test("R8 · H1: a push-to-start activity's update token is registered at once, with its own run")
    func pushStartedTokenRegistersAtOnce() async throws {
        let rig = try await Rig.make()
        // Started on the PWA: this phone hasn't synced the run, and its store isn't bootstrapped.
        try rig.h.write { db in try db.execute(sql: "UPDATE sync_state SET bootstrap_complete = 0") }
        let runId = UUID().wireString
        var state = RunActivityContent.state(
            runId: runId, revision: 1, status: .running,
            state: try RunFold.fold(
                runId: runId, steps: [],
                events: [RunEvent(id: runId, type: .start, at: ms())]), steps: [])
        state.revision = 1
        let id = await rig.center.seed(rig.attributes, state, staleDate: Self.now)
        await rig.token("cd03", for: id)
        await rig.activities.tokensChanged()
        await rig.settle()
        let updates = rig.api.registered.filter { $0.kind == .update }
        #expect(updates.count == 1)
        let update = try #require(updates.first)
        let registeredRun: String? = update.runId
        #expect(registeredRun == runId)
        let topicId: String? = update.topicId
        #expect(topicId == rig.h.topic.id.wireString)
        // Not bootstrapped: the activity is left alone.
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .active)
        // Synced later: the server already had it, so it isn't registered again.
        try rig.h.write { db in try db.execute(sql: "UPDATE sync_state SET bootstrap_complete = 1") }
        try rig.h.seedServerRun(id: try #require(UUID(uuidString: runId)), steps: [])
        await rig.activities.tokensChanged()
        await rig.settle()
        let again = rig.api.registered.filter { $0.kind == .update }.count
        #expect(again == 1)
    }

    @Test("R8 · an update token of this device's own start is registered again once the server knows the run")
    func ownStartTokenRegistersAgainOnceKnown() async throws {
        let rig = try await Rig.make()
        let runId = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let activity = try #require(await rig.center.all().first)
        await rig.token("AB02", for: activity.id)
        await rig.activities.tokensChanged()
        await rig.settle()
        let before = rig.api.registered.filter { $0.kind == .update }.count
        #expect(before == 1, "sent at once (the server doesn't keep it yet)")
        _ = try await rig.h.outbox().flushNow()
        await rig.activities.reconcile()
        await rig.activities.reconcile()
        await rig.settle()
        let updates = rig.api.registered.filter { $0.kind == .update }
        #expect(updates.count == 2)
        let update = try #require(updates.last)
        #expect(update.token == "ab02")
        let registeredRun: String? = update.runId
        #expect(registeredRun == runId)
        let topicId: String? = update.topicId
        #expect(topicId == rig.h.topic.id.wireString)
    }

    @Test("R8 · a failed registration is tried again at the next reconciliation")
    func failedRegistrationRetries() async throws {
        let rig = try await Rig.make()
        rig.api.failing(true)
        await rig.activities.tokensChanged()
        await rig.settle()
        rig.api.failing(false)
        await rig.activities.reconcile()
        await rig.settle()
        let starts = rig.api.registered.filter { $0.kind == .start }.count
        #expect(starts == 1)
    }

    @Test("R8 · M2: a tap's local update doesn't wait for token registration")
    func localUpdatesDontWaitForTokens() async throws {
        let rig = try await Rig.make()
        rig.api.hang(true)
        let runId = try await rig.h.start()
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        rig.h.wall.advance(by: 60)
        _ = try await rig.h.runs().next(runId: runId)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.state.seg == 1, "updated while the registration hangs")
        rig.api.hang(false)
        await rig.settle()
    }

    // MARK: - Which run an activity shows

    @Test("R8 · M1: of several finishing runs, the activity's own; else the newest")
    func finishingRunChoice() async throws {
        let rig = try await Rig.make(requiresAnswers: true)
        let old = UUID()
        let new = UUID()
        for (id, at) in [(old, ms(-600)), (new, ms(-60))] {
            let events = [
                RunEvent(id: id.wireString, type: .start, at: at),
                RunEvent(id: UUID().wireString, type: .stop, at: at + 30_000),
            ]
            let state = try RunFold.fold(runId: id.wireString, steps: OutboxHarness.steps, events: events)
            let run = Run(
                id: id, topicId: rig.h.topic.id, version: 1, status: .finishing, revision: 2, startedAt: at,
                endedAt: state.endedAt, edited: false,
                events: events.enumerated().map {
                    Run.StoredEvent(event: $1, arrival: $0 + 1, effect: .applied, source: "web")
                },
                state: state, aliases: [])
            try rig.h.write { db in _ = try ServerLayer.upsert(db, run: run) }
        }
        let snapshot = try #require(try await RunActivitySnapshot.read(rig.h.store))
        let shownOld = snapshot.run(topicId: rig.h.topic.id, showing: old.wireString)?.id
        #expect(shownOld == old.wireString)
        let newest = snapshot.run(topicId: rig.h.topic.id)?.id
        #expect(newest == new.wireString)
        // A new run opened: an activity still on a finishing run keeps it; others follow the open one.
        let open = try rig.h.seedServerRun()
        let later = try #require(try await RunActivitySnapshot.read(rig.h.store))
        let kept = later.run(topicId: rig.h.topic.id, showing: old.wireString)?.id
        #expect(kept == old.wireString)
        let followed = later.run(topicId: rig.h.topic.id)?.id
        #expect(followed == open.id.wireString)
    }

    @Test("R8 · before the store's bootstrap, an empty view ends nothing")
    func bootstrapGuard() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        await rig.center.seed(rig.attributes, try rig.viewState(server.id.wireString), staleDate: Self.now)
        // A store being rebuilt: no runs yet, bootstrap not complete.
        try rig.h.write { db in
            try ServerLayer.applyDeletion(db, kind: .run, id: server.id, topicId: rig.h.topic.id, seq: nil)
            try db.execute(sql: "UPDATE sync_state SET bootstrap_complete = 0")
        }
        let snapshot = try await RunActivitySnapshot.read(rig.h.store)
        #expect(snapshot == nil)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .active)
        let ends = await rig.center.ends
        #expect(ends == 0)
    }

    @Test("R8 · token passes hold the store resumed")
    func tokenPassesHoldTheStore() async throws {
        let counter = HoldCounter()
        let h = try OutboxHarness()
        try h.timed()
        let api = FakeTokenAPI()
        let tokens = LiveActivityTokens(
            .init(
                register: { try await api.register($0) }, unregister: { try api.unregister($0) },
                deviceToken: { "dev1" }, environment: { .sandbox }, serverId: { api.serverId }))
        await tokens.pushToStart("start01")
        let store = h.store
        let activities = LiveActivities(
            center: FakeActivityCenter(), tokens: tokens, enabled: true,
            snapshot: { (try? await RunActivitySnapshot.read(store)) ?? nil }, now: { Self.now },
            hold: {
                counter.take()
                return { counter.release() }
            })
        await activities.tokensChanged()
        await activities.tokensSettled()
        let taken = counter.taken
        #expect(taken == 2, "the snapshot's read and the pass")
        let held = counter.held
        #expect(held == 0, "every hold released")
    }

    // MARK: - Unknown steps, ids

    @Test("R8 · a request without the steps offers Next, not Lap, and is updated once they're stored")
    func unknownStepsThenKnown() async throws {
        let rig = try await Rig.make()
        // Version 2 is timed on the server only: this phone doesn't have its steps.
        let runId = UUID()
        let start = RunEvent(id: runId.wireString, type: .start, at: ms())
        try rig.h.write { db in
            // The server's state, folded over its version's steps.
            let state = try RunFold.fold(runId: runId.wireString, steps: OutboxHarness.steps, events: [start])
            let run = Run(
                id: runId, topicId: rig.h.topic.id, version: 2, status: .running, revision: 1, startedAt: start.at,
                endedAt: nil, edited: false,
                events: [Run.StoredEvent(event: start, arrival: 1, effect: .applied, source: "web")],
                state: state, aliases: [])
            _ = try ServerLayer.upsert(db, run: run)
        }
        await rig.activities.reconcile(startFor: rig.h.topic.id)
        let requested = try #require(await rig.center.all().first)
        let buttons: [RunActivityDisplay.Button] = RunActivityDisplay(state: requested.state, topicName: "").buttons
        #expect(buttons == [.next, .pause, .stop])
        try rig.h.timed(version: 2)
        await rig.activities.reconcile()
        let updated = try #require(await rig.center.all().first)
        let unknown: Bool? = updated.state.stepsUnknown
        #expect(unknown == nil)
        #expect(updated.state.stepCount == 3)
        let next: String? = updated.state.nextLabel
        #expect(next == "Breakfast")
    }

    @Test("R8 · server ids compare without case")
    func serverIdCase() async throws {
        let rig = try await Rig.make()
        let server = try rig.h.seedServerRun()
        var attributes = rig.attributes
        attributes.serverId = "SERVER-1"
        await rig.center.seed(attributes, try rig.viewState(server.id.wireString), staleDate: Self.now)
        await rig.activities.reconcile()
        let activity = try #require(await rig.center.all().first)
        #expect(activity.phase == .active)
        let made = RunActivityContent.attributes(serverId: "SERVER-1", topicId: rig.h.topic.id, topicName: "T")
        #expect(made.serverId == "server-1")
    }
}

// MARK: - Fakes

/// ActivityKit's activities, in memory.
actor FakeActivityCenter: RunActivityCenter {
    struct Activity: Sendable {
        var id: String
        var attributes: RunActivityAttributes
        var state: RunActivityState
        var staleDate: Date?
        var phase: RunActivityRecord.Phase
        var dismissal: RunActivityDismissal?
    }

    private var list: [Activity] = []
    private var refusing = false
    private var counter = 0
    private(set) var updates = 0
    private(set) var ends = 0

    func all() -> [Activity] { list }

    func refuse() { refusing = true }

    @discardableResult
    func seed(_ attributes: RunActivityAttributes, _ state: RunActivityState, staleDate: Date?) -> String {
        counter += 1
        let id = "a\(counter)"
        list.append(Activity(id: id, attributes: attributes, state: state, staleDate: staleDate, phase: .active))
        return id
    }

    func endNow(_ id: String) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].phase = .ended
    }

    func areActivitiesEnabled() -> Bool { true }

    func activities() -> [RunActivityRecord] {
        list.map {
            RunActivityRecord(
                id: $0.id, attributes: $0.attributes, state: $0.state, staleDate: $0.staleDate, phase: $0.phase)
        }
    }

    func request(_ attributes: RunActivityAttributes, _ state: RunActivityState, staleDate: Date) throws -> String {
        if refusing { throw CancellationError() }
        return seed(attributes, state, staleDate: staleDate)
    }

    func update(id: String, _ state: RunActivityState, staleDate: Date) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        updates += 1
        list[i].state = state
        list[i].staleDate = staleDate
    }

    func end(id: String, _ state: RunActivityState, dismissal: RunActivityDismissal) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        ends += 1
        list[i].state = state
        list[i].phase = .ended
        list[i].dismissal = dismissal
    }
}

/// Counts store holds.
final class HoldCounter: Sendable {
    private let state = Mutex((taken: 0, held: 0))
    var taken: Int { state.withLock { $0.taken } }
    var held: Int { state.withLock { $0.held } }
    func take() {
        state.withLock {
            $0.taken += 1
            $0.held += 1
        }
    }
    func release() { state.withLock { $0.held -= 1 } }
}

/// registerLiveActivity and deleteLiveActivity, recorded; also the active server's id and the
/// persisted owed deletes, which outlive one rig ("launch").
final class FakeTokenAPI: Sendable {
    private struct State {
        var registered: [LiveActivityInDTO] = []
        var deleted: [String] = []
        var failing = false
        var failingDeletes = false
        var hanging = false
        var serverId: String? = "server-1"
        var owed: [String] = []
    }

    private let state = Mutex(State())

    var registered: [LiveActivityInDTO] { state.withLock { $0.registered } }
    var deleted: [String] { state.withLock { $0.deleted } }
    var serverId: String? {
        get { state.withLock { $0.serverId } }
        set { state.withLock { $0.serverId = newValue } }
    }
    var owed: [String] {
        get { state.withLock { $0.owed } }
        set { state.withLock { $0.owed = newValue } }
    }

    func failing(_ on: Bool) { state.withLock { $0.failing = on } }
    func failingDeletes(_ on: Bool) { state.withLock { $0.failingDeletes = on } }
    /// Registrations wait until it's turned off again.
    func hang(_ on: Bool) { state.withLock { $0.hanging = on } }

    func register(_ body: LiveActivityInDTO) async throws {
        while state.withLock({ $0.hanging }) { try await Task.sleep(for: .milliseconds(10)) }
        try state.withLock {
            if $0.failing { throw CancellationError() }
            $0.registered.append(body)
        }
    }

    func unregister(_ token: String) throws {
        try state.withLock {
            if $0.failingDeletes { throw CancellationError() }
            $0.deleted.append(token)
        }
    }
}
