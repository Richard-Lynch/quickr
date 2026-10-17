# Codex review: M1 WP SYNC (round 1). Finding 6 declined: MP and INT are separate WPs.

**REQUEST CHANGES**

Reviewed the committed diff through `HEAD`. Two files also have uncommitted edits; the partial-header fix below is already present there. No files changed or tests run; the workspace is read-only.

1. **Major — Flush takeover bypasses cancelled-create cleanup.** [SyncCoordinator.swift:498](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:498), [PageApplication.swift:184](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/PageApplication.swift:184)  
   Acquiring an expired, owned `flush` lease invokes STORE’s default takeover, which converts `in_flight` items to `uncertain`. The subsequent swap therefore finds no IDs in `leftInFlight`, and `removeCancelledCreates` misses those creates. A cancelled POST remains ahead of its cancellation DELETE and can be resent. This violates cancellation invariant S8.  
   **Fix:** perform cancellation cleanup within the takeover transaction, preserving the affected create IDs before recovery. Add a test with a genuinely owned, expired flush lease. `swapResolvesTheWholeOutbox` fabricates in-flight rows without owning that lease, so it misses this production path.

2. **Major — Connect can join a run for the previous server and falsely report bootstrap success.** [SyncCoordinator.swift:132](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:132)  
   Checking `running` before the onboarding network await does not reserve the coordinator. While connect fetches server B, a sync for A can start. Connect then activates B and calls `run`, which joins A’s task. A can complete with `.synced`, making connect return `.connected(B, …, .synced)` although B’s prefetched page was discarded and B was never pulled. Concurrent connects and reset introduce similar unprotected interleavings.  
   **Fix:** serialize connect/reset/run transitions across awaits, or use an operation generation and revalidate it before activation and joining. Only join a task belonging to the intended store. Test with separately gated connect and live-feed requests.

3. **Major — Reset retirement is not fenced against cancellation of its registry intent.** [SyncCoordinator.swift:605](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:605)  
   Multiple recovery callers can obtain the same persisted intent. One caller can time out and clear it while another holds the leases or is awaiting retirement. `old.retire` checks leases and outbox counts, but never the intent token. The second caller can consequently retire the file after the reset was aborted; `completeReset` detecting supersession comes too late. STORE’s retired-pointer repair can then advance a reset that ostensibly aborted.  
   **Fix:** serialize intent abort/replacement with retirement and ensure the retirement belongs to the still-current attempt. A standalone registry read before retirement leaves another check/act window. Add a gated test that clears the intent immediately before the retirement write.

4. **Major — The partial-header mismatch path omits the coordinator lease fence.** [SyncCoordinator.swift:399](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:399), [SyncCoordinator.swift:555](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:555)  
   This coordinator transaction fences only `notRetired` and `layerGen`. After lease expiry, a newer coordinator can finish a same-layer pull and clear `epoch_suspect`; the suspended old coordinator can then return and set it again. It also ignores the fence result. This violates §5.5’s requirement that superseded coordinator work write nothing and can unnecessarily stop outbox claims.  
   **Fix:** pass the captured live context, including epoch and sync claim, and return `.superseded` on fence failure. Test an old partial-header response released after takeover.

5. **Major — Committed code loses an observed epoch when server identity headers are partial.** [SyncCoordinator.swift:457](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:457), [SyncCoordinator.swift:553](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Sources/QuickrData/Sync/SyncCoordinator.swift:553)  
   At `HEAD`, these use `response.identity?.epoch`; `identity` requires both headers. A classified mismatch carrying only the new epoch therefore fails instead of rebuilding. During staging, repeated such responses strand the rebuild.  
   **Fix:** retain the existing uncommitted change to `response.observed.epoch` and its regression test; also cover the staged path.

6. **Major — Mandatory process/integration gates remain disabled placeholders.** [SyncMatrixStubs.swift:9](/Users/richie/code/quickr-worktrees/ios-m1-sync/ios/QuickrKit/Tests/QuickrDataTests/Sync/SyncMatrixStubs.swift:9)  
   The simulations contain useful state and request-order assertions, but disabled empty tests do not satisfy §13.2 G4/G5. A second pool cannot establish process-death, suspension, or notification behavior.  
   **Fix:** supply and run the required subprocess and backend cases before acceptance, with assertions on durable state and emitted requests.

The principal page and swap transactions otherwise sample lease time inside write closures, apply upserts through STORE guards, and commit cursor advancement atomically. Staging precedes live pulls, and normal flush requests occur after lease release.