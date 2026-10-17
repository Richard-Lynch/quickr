# Codex review: M1 WP STORE (round 2)

**REQUEST CHANGES**

- **Reset completion fencing — NOT RESOLVED in full.** The original consecutive-generation blocker is fixed: `completeReset` compares both `storeGen` and `pendingGen` transactionally; `aStaleRecoveryNeverCompletesANewerReset` covers g1→g2 versus g2→g3. **Remaining Major:** cancellation fencing permits same-generation intent reuse. In [Registry.swift](/Users/richie/code/quickr-worktrees/ios-m1-store/ios/QuickrKit/Sources/QuickrData/Store/Registry.swift:124), `clearResetIntent` compares only `pendingGen`. A delays aborting g1→g2; B aborts it and persists a replacement g1→g2 with fresh confirmation; A resumes and clears B’s replacement. Generation pairs cannot identify distinct attempts. Add a unique reset-intent token, fence abort/completion on it, and test abort→recreate→stale-abort.

- **Lease time sampled before lock — RESOLVED.** Acquisition, renewal, ack and retirement now call `clock.now()` inside their write closures. `LeaseTimeSamplingTests` exercises all four behind a blocked writer while advancing beyond expiry.

- **Sync lease leak on cancellation/error — RESOLVED.** Flush acquisition’s throwing exits and timeout path await cancellation-independent cleanup. Added tests cover cancellation while waiting and a database error.

- **Failed-create exclusion with server row — RESOLVED.** `createFailed` is set before the server-row guard. `isCounted` excludes the entity while retaining server content. The matrix verifies topic counts, version counts and latest-entry exclusion.

- **Overlay matrix — RESOLVED.** Parameterized coverage adds pending/in-flight/uncertain updates and deletes, cancellation deletes, failed creates with server rows, and `deletedElsewhere` with either server presence, through pure and repository paths.

The other requested checks found **no additional Blocker/Major**:

- **Eight-round recovery:** stable recovery completes within the bound; repeated registry changes yield explicit `registryChanged`, not an infinite loop. Callers must retry that error.
- **Completion outcomes:** `alreadyAdvanced` requires exactly the target generation with no pending intent; newer generations/intents return `superseded`. Recovery re-reads after every outcome.
- **Cleanup task:** this is an unstructured `Task`, not `Task.detached`; it does not inherit caller cancellation. Release executes `WHERE name = ? AND token = ?`, so delayed cleanup cannot release a subsequently acquired lease.
- **C1:** topic repositories return `ViewTopic`; overlays propagate pending kind and latest failure/error. Server, create and patch answers use version-specific questions. `QuestionBook` caches by topic/version within one read transaction, avoiding cross-transaction stale cache data.

Minor: `QuestionBook` swallows SQL/decoding errors, silently degrading normalization; propagate operational errors.

Static review only; tests were inspected, not rerun in the read-only workspace.