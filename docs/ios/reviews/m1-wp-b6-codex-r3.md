# Codex review: M1 WP B6 (round 3)

**REQUEST CHANGES**

The Round-2 Major is **resolved for fan-outs completing within two days**, but remains possible because pruning deletes progress for active, unfinished slots.

- **Major — active progress expires.** `_record_progress()` unconditionally deletes rows older than two days, including the current slot’s completed targets. If fan-out exceeds the work achievable during that window, earlier targets become pending again and can permanently starve the tail and later topics. A small simulation of the implemented policy—six targets, one completion per daily tick—produced `0,1,2,3,0,1,2,3…`; targets 4–5 never ran. Long scheduler outages also cause duplicate sends after stale progress is pruned. Preserve progress for currently due, unfinished slots; apply TTL cleanup to abandoned slots. Add a regression crossing the TTL while the slot remains active.

Other checks:

- **Failed targets count as reached:** correct; finished failures/gone targets are recorded, matching the existing best-effort semantics. Deadline cancellations remain pending.
- **Normal delivery:** persisted target filtering and oldest-slot ordering provide forward progress and one completed attempt per target/slot within the retention window.
- **At-least-once:** preserved across rollback/commit failure; progress and notification marks share the transaction.
- **New entries:** recomputing due status stops resuming a satisfied slot; abandoned rows eventually expire. Entries arriving during delivery retain the existing snapshot behavior.
- **Topic deletion:** the insertion’s topic join skips already-deleted topics; cascading deletion cleans existing progress.
- **Scheduler lock:** remains transaction-scoped through progress, marking, and commit.
- **Migration:** chain, composite key, constraint, cascade, and downgrade match the model.

No additional Blocker/Major identified. Validation: source/test inspection and pruning-policy simulation; full suite not run.