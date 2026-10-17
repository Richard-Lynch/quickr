# Codex review: M0 milestone

**BLOCK**

Blocker: none found. Two Majors remain.

**Major**

- **Response headers can cause connection-pool starvation.** [identity.py:82](/Users/richie/code/quickr-worktrees/ios/backend/app/api/identity.py:82) opens a second database session before sending ordinary responses. Read handlers still retain their first connection through the request-scoped [get_db dependency](/Users/richie/code/quickr-worktrees/ios/backend/app/db.py:20). If concurrent reads occupy the pool, each can wait for a header connection while withholding the connection needed by another request. Pool timeouts are swallowed, producing delayed responses without the identity headers iOS requires. This affects existing PWA reads too. **Fix:** obtain post-handler identity using the request’s connection, or release that connection before acquiring another; preserve snapshot-bound headers for feed/CSV. Add a bounded-pool concurrency regression.

- **A side-effecting endpoint bypasses the identity contract.** [routes.py:387](/Users/richie/code/quickr-worktrees/ios/backend/app/api/routes.py:387) omits `ExpectIdentity` on `/push/test`. Supplying deliberately incorrect Expect headers still sends notifications and commits subscription updates/deletions. This contradicts sync F10 and README’s promise that mismatches execute no effects. [test_identity.py:159](/Users/richie/code/quickr-worktrees/ios/backend/tests/test_identity.py:159) explicitly exempts it because it supposedly “writes nothing the client keeps,” overlooking external delivery and subscription mutations. **Fix:** check identity atomically before delivery, coordinating with epoch rotation; remove the exemption and test zero deliveries and database changes on mismatch. Avoid wrapping external sends in an automatically replayed transaction.

**Minor**

- **Fixture completeness is overstated.** [shared/fixtures/README.md:66](/Users/richie/code/quickr-worktrees/ios/shared/fixtures/README.md:66) claims every operation is covered. Comparing committed fixtures against OpenAPI finds six missing: `unarchiveTopic`, `deleteTopic`, `exportEntriesCsv`, `createPushSubscription`, `deletePushSubscription`, `sendTestPush`. The fixture drift test checks only its manually recorded scenario, so omissions pass. **Fix:** add the required fixtures and an operation-coverage assertion with explicit exclusions for deferred/platform-specific operations and non-JSON exports. Request goldens remain legitimately M1 work.

- **The checked topic-deletion claim contradicts the integrated contract.** [STATUS.md:144](/Users/richie/code/quickr-worktrees/ios/docs/ios/STATUS.md:144) says deletion emits a deletion for every child. Implementation tombstones every child but logs only the topic deletion; incremental clients cascade locally. Historical child rows yield explicit child deletions during bootstrap. That agrees with sync F3, so **fix STATUS**, rather than changing server behavior.

- **Gate and progress documentation have drifted.** [Makefile:68](/Users/richie/code/quickr-worktrees/ios/Makefile:68) claims CI parity, but `make check` omits CI’s OpenAPI and generated-client freshness checks. [STATUS.md:166](/Users/richie/code/quickr-worktrees/ios/docs/ios/STATUS.md:166) associates `alembic check` with that gate, although Make does not invoke it; pytest separately compares migration metadata. STATUS’s “Now” section still awaits an installed Xcode and schedules already-merged work. Its vector inventory is also stale: committed quick-log vectors contain **380 cases**, and API fixtures number **32**. **Fix:** distinguish commands actually run from equivalent checks, add freshness checks to Make or narrow its description, and refresh current claims.

The remaining M0 §7 validation items have concrete tests: concurrent commit ordering, deletion-only pages, backfill/epoch behavior, deleted-id replay, MCP deletion propagation, enum downgrade, and fixture/vector drift. The migration chain is linear; downgrade preserves server identity while forcing a new epoch on re-upgrade. The documented in-place migration edit is acceptable under the stated never-deployed history.

Rules 1–6 and 13 are represented in backend code, subject to the endpoint exception above. Client rules 7–12 and 14–16 are specified for later implementation; scaffold smoke tests do not prove them. CI explicitly selects iOS 26.x, and `make check` remains Xcode-free.

No new secret exposure found: feed records reuse existing topic/version/entry response models, excluding push credentials and private settings. Permanent deletion identifiers, timestamps, and stable server identity are additional intentional metadata.

Validation performed: **18 due/quick-log tests passed**; static code, contract, migration and workflow review. Full database, frontend and Xcode gates were not rerun, so historical green-run claims remain unverified here.