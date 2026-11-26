# M3a sync-m1: Codex review

## Round 1 (merge d237693a conflict resolutions + store migration fb916ca6)

- **Medium — The migration test does not exercise an actual mid-rebuild store.** [StoreMigrationOrderTests.swift](/Users/richie/code/quickr-worktrees/t2-m3a-sync-m1/ios/QuickrKit/Tests/QuickrDataTests/Upgrade/StoreMigrationOrderTests.swift:96) populates staging and advances its cursor, but does not set `sync_state.rebuilding` before reopening the store. It therefore does not prove that migration preserves an existing target epoch when it differs from the live epoch. It also seeds only `stage_topic`, `stage_entry`, and `stage_tombstone`; checking every table is empty afterward would not catch a missing delete for the other tables. The test does check cursor zero, the rebuild flag for a previously synced store, `stage_run_closed` after conversion, themes after one sync, and the selected M1 data.

- **Low — The migration contract and its required order test are stale.** [t2-plan.md](/Users/richie/code/quickr-worktrees/t2-m3a-sync-m1/docs/specs/t2-plan.md:251) says either milestone migration order is valid and requires a fresh-store test in both orders. [StoreSchema+T2M3.swift](/Users/richie/code/quickr-worktrees/t2-m3a-sync-m1/ios/QuickrKit/Sources/QuickrData/Contracts/StoreSchema+T2M3.swift:34) now depends on M1’s staging table already existing, and the new test checks only M1 first. The implementation and plan should agree on the intended contract.

- **Low — The MCP shared-file additions are not delimited as specified.** [mcp_server.py](/Users/richie/code/quickr-worktrees/t2-m3a-sync-m1/backend/app/mcp_server.py:90) retains the appearance instructions and M1 timing text, but the M3 additions have no `T2-M3` opening and closing comments and are interleaved with existing declarations. This violates the shared-file merge convention in the plan and makes future milestone merges harder to audit.

I found no other conflict-resolution behavior loss in the reviewed changes. The Live Activity appearance additions and M1 content-state change remain present. The migration test explicitly records the issue #274 limitation: a rebuilt layer regains the closed run’s marker but not its alias marker. The test was reviewed statically; I did not run the suite.

## Round 2 (after 1b555fac)

No remaining findings against finding (1).

The revised test seeds every pre-T2 staging table, including run tombstones that M1 converts into `stage_run_closed`. It checks that every stage table is empty after migration, the stage cursor is zero, and rebuilding is set. After one sync, it checks themes, the open run and aliases, the closed-run marker, and entry revisions.

The separate mid-rebuild case verifies that an existing `E2` target is retained while staging restarts. The test also explicitly documents the closed run’s alias marker being absent after the re-pull under the existing behavior tracked in issue #274.
