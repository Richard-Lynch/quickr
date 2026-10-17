# Codex review: M0 WP specs (round 1)

**Verdict: NOT READY.** The specs address many prior findings, but still permit lost undo state, stale writes, cross-server delivery, and unsafe rebuild/reset races.

### Blocker

1. **outbox §8 C3–C5, §9.2 — Delete-with-undo destroys the work needed to undo.** Deleting a never-sent create invokes C3 immediately, dropping the create and its edits without retaining a held delete. Undo cannot restore it. For an existing entry, C4 drops queued updates before the delete’s undo window closes; undo restores the old server row, losing those edits. **Fix:** while deletion is held, preserve the complete preceding overlay. Apply destructive coalescing only when the hold releases; undo removes only the held deletion.

2. **outbox §7.4 — A stale sender can rebase and overwrite newer intent.** A loses its lease; B replays U1 and sends U2. A then receives `stale_revision`, fetches U2’s revision, and resends U1 against it. Revision checks now allow the overwrite. CAS during final bookkeeping is too late. **Fix:** every rebase, revision update, and resend must verify current lock ownership, claim token, and epoch. A superseded sender must stop. Add this sequence to test 32; its present expectation stops at the first 409.

3. **sync §8.3 — Response identity checks happen after data has reached the wrong server.** A matching health response remains valid for 60 seconds. If the URL changes backend during that interval—or between health and POST—the queued write executes on another server before its response reveals the mismatch. **Fix:** send an expected server identity on every mutation and require the backend to reject mismatches before executing. Apply this to APNs registration/unregistration too.

### Major

4. **sync §§5.2, 6–7 — Epoch fencing covers local claims, not the actual server response.** A write claimed under E1 can execute after the backend restores to E2. Responses have no required epoch; the client may acknowledge work against the wrong generation. Conversely, online-only responses have no defined claim epoch and can arrive after a swap, inserting pre-restore rows or tombstones into E2. **Fix:** require response epochs and mutation epoch preconditions; capture a local generation for every request and reject obsolete outcomes, including deletions.

5. **sync §§5.1, 7, 12–13 — Lease ownership does not fence page application or reset.** A suspended pull can outlive `sync_lock`, then apply its old page after a successor rebuilt the store. Page checks lack request-generation and lock-token checks. Reset takes flush then sync locks, whereas rebuild holds sync then waits for flush. Deleting SQLite files also leaves other processes’ existing pools uncoordinated; a Darwin notification does not prove they closed. **Fix:** fence every page/staging/swap transaction, specify one lock order, and coordinate reset through registry generations and process reopening—prefer a fresh store filename.

6. **outbox §8 C1/C2/C8 — Coalescing crosses topic ordering barriers.** Start with an archived topic: enqueue unarchive, create E, then archive. C8 cancels the unarchive and enqueues nothing, leaving E to hit an archived server. Similarly, merging a later edit into an earlier item moves it before intervening topic operations. **Fix:** coalesce only within a contiguous ordering segment with no intervening operation in the affected topic scope.

7. **outbox §6.2 — Clock rollback can strand the flush lock.** Moving the clock backward makes `expires_at` remain in the future potentially for hours; the stated “worst case is an early takeover” is false. **Fix:** use a shared boot-relative clock plus boot identity, or explicitly invalidate leases on discontinuities. Test both clock directions.

8. **notifications §§5.2–5.3 — Registration is not transactionally established.** `setNotificationCategories` supplies no completion barrier proving the system applied a replacement before SQLite commits. Pruning also awaits delivered notifications inside the transaction, conflicting with sync §13’s prohibition on suspension points. Apple documents the [replacement API](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/setnotificationcategories(_:)), not the cross-process ordering guarantee assumed here. **Fix:** revise PLAN rule 9 alongside the spec: snapshot delivered notifications outside SQLite, use a dedicated registration coordinator with reconciliation, and device-test concurrent replacement. Pruning `prunable` rows younger than seven days also contradicts rule 9; retain pending/incoming references.

9. **notifications §§6–8 — Inactive reminders corrupt the active badge.** NSE computes from the payload’s store, and the action handler sets its store’s due count even when inactive. Both contradict §8. The NSE also forcibly counts the incoming topic as due after detecting it was satisfied. **Fix:** badge calculations must use only the active store and its actual derived state; skip writes when unavailable.

10. **Test matrices / PLAN rule 12 — Coverage claims exceed specified tests.** No explicit matrix proves operationId fixture/request-golden coverage or minimum-iOS execution. Missing races include stale rebasing, staged-page takeover, online-response/swap, reset with open extension pools, and reversible deletion of queued overlays. **Fix:** add these as mandatory gates. N11 should also cover malformed/missing entitlement data; XML substring extraction needs an explicit failure path rather than silently choosing an APNs environment.

### Simplifications

- Remove optional NSE flushing; keep its work bounded to notification preparation.
- Use one coordinator for pulls and rebuilds.
- Keep categories without pruning initially; reconsider after measuring growth.
- Reduce coalescing to adjacent, never-attempted operations.
- Require identity, epoch, and revisions on the new client contract; update the PWA together where cleaner.