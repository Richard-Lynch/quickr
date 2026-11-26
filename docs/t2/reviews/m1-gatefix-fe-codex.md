**Two issues remain:** the absorbed-pause fix does not cover removes made from an entry, and the cross-tab alert claim is not atomic.

- **P3 — Entry-origin gap removes still project the absorbed pause incorrectly.** [actions.ts](/Users/richie/code/quickr-worktrees/t2-m1-gatefix-fe/frontend/src/lib/runs/actions.ts:445) takes the `fromEntry` path when the stopped run is no longer in the local view; that path cannot populate `gap`. For example, pause at 0:30, stop at 1:00, reopen at 1:30, then stop again. Removing the first stop’s gap from the entry offline drops the entire 0:30–1:30 pause in the projection, although the fold retains it under the original pause ID. The projection remains wrong until the acknowledgement. The new projection test supplies `gap` manually, while the action test uses a run with its events available, so neither exercises this entry-origin path.

- **P3 — Two tabs can still fire the same alert concurrently.** [RunAlerts.tsx](/Users/richie/code/quickr-worktrees/t2-m1-gatefix-fe/frontend/src/components/runs/RunAlerts.tsx:68) performs a read followed by a write to `localStorage`; those operations are not an atomic claim across tabs. If both tabs read before either writes, both return `true` and fire. Concurrent writes can also overwrite each other’s recorded keys. The test covers a tab observing a claim that was already stored, but does not exercise concurrent claims.

Test coverage for the requested fixes:

| Fix | Does the test exercise it? |
| --- | --- |
| P1-1: reopen → revert → reopen status | **Yes** |
| P2-1: reopen waits for an earlier pending finish | **Yes**, including a retrying finish |
| P2-3: presentation model port | **Yes**, for the requested actions, headlines and alert lines |
| P2-4: shared builder vectors | **Yes**, against the shared fixture |
| P2-5: queued remove in the resuming projection | **Yes**, for a pause remove queued before reopen |
| P3-1: absorbed pause on gap removal | **Partially**; the projection test injects metadata that entry-origin removes do not provide |
| P3-2: overlay `too_long` | **Yes** |
| P3-3: builder whitespace trimming | **Yes**, including U+0085 and U+FEFF |
| P3-7: fired alerts across tabs | **Partially**; sequential observation is tested, concurrent claims are not |
| P3-8: skip alerts at or before zero | **Yes** |

This is a static review; I did not run the test suite.