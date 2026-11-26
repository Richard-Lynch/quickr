**P2 — iOS loses a queued remove in the resuming projection.** [RunOverlay+Reopen.swift](/Users/richie/code/quickr-worktrees/t2-m1/ios/QuickrKit/Sources/QuickrData/Store/RunOverlay+Reopen.swift:108), spec §5.3 and R26. Offline, remove a pause or lap boundary from a stopped entry, then reopen that entry before the remove is acknowledged. `resuming` constructs the run from the original stored timing, without applying the queued remove. Once the resuming run exists, `entryProjection` also skips removes for that run. The reopened clock or lap label therefore reflects the removed boundary until sync corrects it. Apply preceding queued removes to the stored timing before constructing the resuming state, and cover remove → reopen while offline.

**P1:** None found.

**P3:** None found.
## Resolution (added by t2-m1-evidence)

P2-5 (a queued remove is lost in the resuming projection) is fixed on both
clients. iOS: #263 `8375ea32`, test `RunLocalViewTests/removeThenReopenOfAnEntryOffline`.
PWA: #262 `dd8bf410`, test `localView.test.ts` "remove → reopen offline: the
resuming run has the queued remove applied (P2-5)". See the Resolution table in
`M1-milestone-claude.md`.
