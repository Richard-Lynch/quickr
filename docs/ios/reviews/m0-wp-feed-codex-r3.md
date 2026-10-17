# Codex review: M0 WP feed (final check)

REQUEST CHANGES

- **(a) RESOLVED.** `feed.py:86–99` acquires the advisory lock, then checks expected identity inside each retry attempt, before mutation and commit. `rotate_epoch`, `subscribe`, and `unsubscribe` use `@writer`; their internal commits are removed. Lock-wait regression tests cover entry creation and subscription creation.

- **(b) RESOLVED.** `routes.py:322–325` sets `/changes` headers from the returned page’s identity, read within its REPEATABLE READ snapshot. Middleware preserves both headers without appending duplicates.

- **(c) NOT RESOLVED for streaming responses.** Ordinary responses now read identity at `http.response.start`, after handler execution. However, CSV data is queried later; see the Major below.

- **(d) RESOLVED for CORS and redundant middleware lookups.** `main.py:36–43` places CORS outside identity middleware, including its generated 500 responses. Header lookup uses one identity SELECT once initialized. Literally “one identity query per request” is broader than implemented: expected-identity mutations also query under lock, and `/changes` performs initialization and snapshot reads. Those additional reads serve correctness.

- **(e) RESOLVED under the stated deployment history.** The migration docstring explicitly documents the in-place composite-key correction, its never-merged/deployed status, and recreation of affected throwaway databases.

**NEW Major — streamed CSV can carry an epoch older than its data.** [entries.py:291](/Users/richie/code/quickr-worktrees/ios-m0-feed/backend/app/services/entries.py:291) queries successive pages during body streaming (`:298`), after identity headers have been sent. Reproduction: receive headers with epoch A; rotate to B; commit an entry; resume CSV pagination. READ COMMITTED permits B-era rows under header A. The added streaming test rotates before response start, so misses this race. Fix by materializing before headers, or reading identity and all export data from one stable snapshot and supplying that snapshot’s headers.

No additional Blocker/Major found in contextvar scoping (`finally` resets the token), current push/scheduler callers, or header duplication.

Static review only; tests were not executed in this read-only environment.