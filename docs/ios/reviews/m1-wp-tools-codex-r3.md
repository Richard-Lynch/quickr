# Codex review: M1 WP TOOLS (round 3)

**REQUEST CHANGES**

- **Synthetic 1xx — RESOLVED.** `Rule.from_json` now restricts statuses to 200–599 (`backend/tools/faultproxy.py:369`). Direct probes rejected 100/103/199/600 and accepted 200/599. Added tests cover final responses and subsequent keep-alive synchronization.

- **Non-ASCII header values — RESOLVED.** Both `content_type` and `retry_after` require printable ASCII (`faultproxy.py:353`). Direct probes rejected emoji and accented characters in both fields; ordinary ASCII passed.

- **Stale-lock takeover — NOT RESOLVED (Major).** Owner/liveness checks fix age-based eviction, but the ownership check and deletion remain separate operations ([sim-clone.sh:36–37](/Users/richie/code/quickr-worktrees/ios-m1-tools/ios/scripts/sim-clone.sh:36)). Two contenders can both verify the same dead owner. Contender A removes that lock and acquires its replacement; contender B then executes its already-authorized `rm`, deleting A’s live lock, and acquires another. Both enter simulator operations concurrently. The ownership comparison therefore does not guarantee safe takeover. Recovery needs serialization that prevents a delayed contender from unlinking a replacement lock.

**NEW Blocker/Major:** No separate new finding; the existing lock-exclusion Major persists through the takeover race.

Validation: direct Python rule-validation probes and static review of the commit. Full pytest and simulator execution were not run.