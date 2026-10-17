# Codex review: M1 WP C1 (round 2, approved with minors)

**APPROVE WITH MINORS.** No new Blocker/Major found in the five C1 commits, excluding the `ios/m1-data` merge.

Round-1 findings:

- **Notification `quick_log` / `origin` — RESOLVED.** [NotificationCenterProtocol.swift](/Users/richie/code/quickr-worktrees/ios-m1-c1/ios/QuickrKit/Sources/QuickrData/Contracts/NotificationCenterProtocol.swift:94) retains the typed choice/number descriptor, URL and origin; absent origin defaults to remote. Tests verify descriptor preservation and both local/remote arrival orders.
- **Missing `ViewTopic` — RESOLVED.** `TopicRepository` now returns `ViewTopic` from list and single-topic reads. It carries the topic, sync state, pending change and last error; its contract specifies active overlays and failed-operation behavior.
- **Required-nullable response keys accepting omission — RESOLVED.** `RequiredKey` covers topic, question, stats, Problem and APNs nullable response fields. Fixture mutation tests remove individual response keys and require failure; explicit-null tests cover topic fields.
- **Numeric answer normalization — RESOLVED.** Question-aware `domainAnswers(for:)` restores whole-valued doubles after request-shaped persistence. The outbox round-trip test exercises `7.0`; update normalization preserves null removals.
- **WireDate profile — RESOLVED.** Sync §1.5 and `WireDate` now explicitly define the restricted profile: at most six fractional digits, mandatory offset, no leap seconds, microsecond precision.

Additional review:

- **`RequiredKey`: correct by inspection.** Codable synthesis operates on the nonoptional wrapper backing property, using `decode`, so omission throws. The wrapper accepts JSON null and encodes nil as explicit null. Its generic `Codable & Sendable & Hashable` constraints support the synthesized conformances without unchecked Sendable.
- **APNs contracts match** `backend/app/schemas/api.py`, routes and the three shared fixtures: operation IDs, POST paths, registration metadata, environment values, strict nullable output fields, timestamps, empty delete response and test-result response. Required `apns_enabled` is included.
- **Notification payload keys match** notifications §2/§11, including `total_options`, `last_value`, `quick_log` and `due_since`. Unknown keys are ignored.
- **Input/output split is appropriate:** response questions/schedules require their output keys; separate request DTOs preserve omitted defaults. Schedule PATCH retains absent/null/value semantics.

**Minor:** `ReminderDedup.identifiersToRemove` correctly implements delivered-notification selection for L1–L3, scoped by server/topic/slot. It does not itself cancel pending local requests or suppress foreground presentation; those remain adapter responsibilities. Add a fake-center orchestration test covering L1 pending cancellation and L2 suppression/activation cleanup—the current tests establish removal selection only.

Validation was static inspection of source, schemas, fixtures and tests; builds/tests were not rerun in this read-only environment.