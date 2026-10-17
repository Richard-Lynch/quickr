# Codex review: M1 WP STORE (round 3, approved)

**APPROVE**

- **Major: reset-intent fencing — RESOLVED.** `Registry.persistResetIntent` generates a fresh UUID token per attempt. `clearResetIntent` predicates on server ID and token; `completeReset` transactionally checks source generation, target generation, and token before advancing or recording retirement. `StorePartitions` carries the token through abort, completion, recovery, and registry-state comparisons. `aStaleAbortOrCompletionNeverTouchesAReplacementAttempt` covers abort → recreate at the same generation → stale abort/completion, verifies the replacement remains intact, then completes it successfully.

- **Minor: QuestionBook swallowing errors — RESOLVED.** `QuestionLookup` now throws; `QuestionBook.questions` propagates SQL and decoding errors through repository reads and overlay normalization. Missing rows still intentionally fall back to current-topic questions, then `[]`. `unreadableQuestionsFailTheReadInsteadOfSkippingNormalization` verifies malformed questions fail both single-entry and list reads.

- **Schema change in v1 — acceptable given nothing shipped**, provided existing development registries are disposable/recreated. An already-migrated v1 database will not acquire `pending_token` merely by editing v1; retaining those databases would require a new migration.

**No new Blocker/Major found in `git diff 5ab94e3...HEAD`.** Static review only; tests inspected, not rerun in the read-only workspace.