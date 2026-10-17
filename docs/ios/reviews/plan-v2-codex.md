# Review of PLAN.md v2: Codex, second round

**Verdict: NOT READY. V2 improves the architecture, but undo safety, feed completeness and server isolation still need binding protocol rules before implementation.**

Statuses below assess the **plan’s adequacy**, not implementation completion. `docs/ios/specs/` does not yet exist.

**Prior Blocker/Major findings**

| Finding | Status — reason |
|---|---|
| Codex B1: lossless cursor | **PARTIAL** — locking can establish commit order, but pagination/materialisation, cascades and derived topic changes remain unspecified. |
| Codex B2: undo versus leases | **PARTIAL** — permanent tombstones help, but DELETE-before-create and atomic tombstone checks are not defined. |
| Codex B3: destructive resync | **PARTIAL** — preserving overlays is correct; a separate DB “per URL and epoch” can strand the preserved outbox. |
| Codex M4: convergence | **PARTIAL** — tombstones fail dependent operations, but failed-overlay visibility, discard and acknowledgement reconciliation remain deferred. |
| Codex M5: notification meaning | **PARTIAL** — immutable categories fix mutation; concurrent full-set registration can still remove categories. |
| Codex M6: feasibility/fallback | **RESOLVED** — M1 spike and day-one device gate require a decision on failure. |
| Codex M7: fallback deduplication | **PARTIAL** — explicit cancellation is promised, but both arrival orders and slot reconciliation lack concrete rules. |
| Codex M8: shared GRDB | **PARTIAL** — subprocess tests improve coverage; suspension, extension-before-migration and migration/observation recovery remain incomplete. |
| Codex M9: widget delivery | **RESOLVED** — durable enqueue, opportunistic flush, queued presentation and next-trigger delivery are explicit. |
| Codex M10: exactly-once scheduler | **PARTIAL** — exactly-once is removed, but send-then-mark still cannot guarantee “at least once” per target. |
| Codex M11: development deployment | **RESOLVED** — worktree Docker builds, LAN access and key mounting provide a concrete route. |
| Codex M12: parity validation | **PARTIAL** — contracts, integration and chart tests improve coverage; explicit minimum-iOS execution and complete endpoint coverage remain absent. |
| Fable B1: broken host toolchain | **RESOLVED** — Swift compilation waits for H1/H2; backend work can proceed. |
| Fable B2: action count | **RESOLVED** — four-action ceiling replaces seven actions; presentation still needs device proof. |
| Fable B3: outbox scope | **RESOLVED** — acknowledged as a new XL design with dedicated specification and tests. |
| Fable M1: toolchain mismatch | **RESOLVED** — explicit deployment/tools/API compatibility policy replaces identical-version pinning. |
| Fable M2: shortcuts provider | **RESOLVED** — app-target placement and app/widget resolution proof are explicit. |
| Fable M3: Action button hardware | **RESOLVED** — hardware prerequisite and phone-model check are explicit. |
| Fable M4: sync edge cases | **PARTIAL** — timestamp sites are covered; cascade, overlay and resync semantics remain incomplete. |
| Fable M5: sequencing | **RESOLVED** — split M2, earlier reminders/widgets and checkpoint D address the finding. |
| Fable M6: CI budget | **PARTIAL** — local compilation and reduced CI are specified; plan-tier confirmation remains outstanding. |
| Fable M7: badge source | **RESOLVED** — payload omits badge; device owns it. |

**New-design findings**

1. **Blocker — deletion must reserve an absent ID.** `entries.py:200–205` currently loads the entry before deletion; missing IDs return 404. Counterexample: POST is delayed, Undo DELETE returns 404, client considers it done, POST then creates the entry. Require DELETE to atomically insert `deleted_ids` even when absent, and serialize create’s tombstone check/insert against deletion. A permanent table alone provides neither guarantee.

   Conversely, POST committed → response lost → replay returns existing entry → queued DELETE is valid. If replay returns `entry_deleted`, retire the create **without materialising an entry or retaining its optimistic overlay**. B4 covers the PWA classifier, but `outboxEffects.ts` also needs deletion reconciliation; older cached PWA code classifies 409 as terminal.

2. **Major — late feed locking preserves order, but risks deadlocks.** One common exclusive transaction lock, acquired **before every `nextval`** and held through commit, orders committed feed transactions even when acquired late. [PostgreSQL releases transaction advisory locks at transaction end.](https://www.postgresql.org/docs/17/explicit-locking.html) However, a transaction holding topic A then waiting for the feed lock can deadlock with its holder waiting for A. Define lock order before row/FK locks and automatic transaction retries. Scheduler lock `0x716B7201` needs a distinct key and explicit interaction policy; it currently uses nonblocking acquisition, so a two-advisory-lock deadlock is not established by existing code alone.

3. **Major — service coverage is insufficiently enumerated.** REST and MCP share services, correctly. But topic deletion cascades through database FKs (`models.py`); child entry/version deletions bypass entry services. Require child tombstones or explicit parent-cascade semantics, plus permanent entry-ID reservation. Entry mutations also change computed `entry_count`, `last_captured_at` and due state (`topics.py:88–137`): log topic invalidation or mandate local recomputation. Define bounded feed-page cursors and consistent handling when “latest state” disappears during materialisation.

4. **New Blocker — server partitioning omits notification provenance.** Old notifications can survive a server switch; payloads identify topic/version, not server. Their actions could enqueue into the active server’s store. Pin server identity in every notification/action and outstanding request. Define atomic epoch-store migration preserving outbox, credentials and operation ownership.

5. **Major — category registration still races.** A reads `{A}`, B registers `{A,B}`, A later registers `{A}`. Serialize cross-process registration and retain in-flight/pending categories too. Hash the complete ordered action descriptor. [Four actions is a maximum, not guaranteed presentation.](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SupportingNotificationsinYourApp.html)

6. **Major — remaining semantics:** expired senders can overwrite newer PATCH/archive operations; two-layer acknowledgement must atomically avoid double overlays; restore must actually rotate epoch; scheduler partial failures remain best-effort, without per-device retry guarantees.