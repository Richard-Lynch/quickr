# Codex review: M1 WP tools (round 1)

**REQUEST CHANGES**

No Blockers found; these Majors should be fixed before INT/MP suites depend on the harness.

- **Major — HTTP response framing:** `backend/tools/faultproxy.py:525` treats an upstream `100`/`103` as the final response, closes upstream, and discards the actual response. The client then waits for a final response on a kept-open connection. At `:129`, synthetic responses also send bodies for HEAD and bodyless statuses, potentially desynchronizing subsequent requests. **Fix:** consume interim responses until the final status; make encoding method/status aware, including correct HEAD/304 length handling. Add raw-wire tests with consecutive requests.

- **Major — Incomplete hop-by-hop filtering:** `backend/tools/faultproxy.py:132` and `:511` remove only fixed header names. Headers nominated by `Connection` are forwarded in both directions. **Fix:** parse all Connection tokens and exclude those named headers alongside the fixed set; test request and response filtering while preserving identity and conditional headers.

- **Major — Invalid control input crashes handlers:** `backend/tools/faultproxy.py:258` and `:607`. Direct probes confirmed `{}` raises an uncaught missing-action `TypeError`, `garble: []` raises `TypeError`, and `/upstream` with `name: []` does likewise. Invalid body/field types can also install rules that crash later proxy requests. **Fix:** validate every field’s type before construction/membership checks, reject CR/LF in header values, and consistently return JSON 400 without installing invalid rules.

- **Major — Port allocation race:** `ios/scripts/integration-common.sh:33`. Probing does not reserve ports; worktrees hashing to the same block can both select it while their images build. One subsequently fails startup. **Fix:** coordinate allocation across worktrees with a lock/reservation retained until Docker binds, or use Docker-assigned ports and inspect them. Add a simultaneous-start collision test.

- **Major — Standalone startup leaks stacks:** `ios/scripts/integration-up.sh:31`. After Compose succeeds, health-header failures, identity checks, or env-file creation failures exit without teardown. Only the Compose-up failure branch cleans up; the outer wrapper protects `make ios-integration`, but not `make ios-integration-up`. **Fix:** install startup EXIT/INT/TERM cleanup and disarm it only after successful initialization.

- **Major — Simulator isolation uses basename only:** `ios/scripts/sim-clone.sh:18`. Different worktree paths with identical directory basenames select the same simulator; `--delete` can delete another worktree’s device. **Fix:** include a canonical-path hash, and serialize lookup/create for concurrent invocations.

- **Minor — Generated shell file breaks on spaces:** `ios/scripts/integration-up.sh:47` writes an unquoted script path that is subsequently sourced. **Fix:** emit shell-escaped assignments, for example with Bash `printf '%q'`.

- **Minor — Parser/resource hardening:** `backend/tools/faultproxy.py:177`. Chunk terminators are not validated; negative/conflicting lengths and malformed chunk sizes are not handled consistently. Bodies, trailers, and idle reads have no practical limits. **Fix:** reject invalid framing, bound buffering/trailers, and add read deadlines.

The normal `drop_response` path awaits the complete upstream response before aborting the client, supporting commit-before-loss. Rule selection/counting is atomic between awaits; holds leave control traffic available. Docker host publications bind loopback, and scripts inherit `set -euo pipefail`. The mypy scope change is appropriate.

Tests lack adversarial framing, large-body, collision, and failure-cleanup coverage. Pytest execution was blocked by the read-only sandbox’s temporary-file restriction; control-validation probes ran successfully.