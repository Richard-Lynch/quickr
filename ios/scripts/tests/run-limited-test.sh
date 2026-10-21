#!/usr/bin/env bash
# shellcheck disable=SC2034 # rc and start are read inside check's eval strings
# Tests for common.sh run_limited: a command within its limit keeps its status; past it, its
# whole process group stops (grandchildren and a pipeline included, as xcodebuild sits under
# test.sh's watchdog pipeline), a TERM-ignoring member is KILLed after the grace, the status is
# 124, and nothing outside the group is touched.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
set +e
export IOS_LIMIT_GRACE_SECS=2
failures=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi; }
alive() { kill -0 "$1" 2>/dev/null; }
work="$(mktemp -d "${TMPDIR:-/tmp}/quickr-limit.XXXXXX")"
bystander=""
# Whatever a failing run left behind is stopped here, by the PIDs the fixture recorded.
trap 'for p in $(cat "$work"/pids 2>/dev/null) $bystander; do kill -KILL "$p" 2>/dev/null; done; rm -rf "$work"' EXIT

# 1. Within the limit: the command's own status, without waiting for the limit.
start=$SECONDS
run_limited 30 bash -c 'exit 3' 2>/dev/null
rc=$?
check "a command within its limit keeps its status (3)" '(( rc == 3 ))'
check "and returns without waiting for the limit" '(( SECONDS - start < 10 ))'

# 2. Past the limit: a three-level tree with a pipeline; ready (every pid recorded) before
#    the limit can pass. A bystander outside the group.
fixture="$work/fixture.sh"
cat >"$fixture" <<SH
#!/usr/bin/env bash
bash -c 'sleep 60 & echo \$! >> "$work/pids"; sleep 60 | cat & echo \$! >> "$work/pids"; wait' &
echo \$! >> "$work/pids"
sleep 60 &
echo \$! >> "$work/pids"
until [[ \$(wc -l < "$work/pids") -ge 4 ]]; do sleep 0.1; done
echo ready > "$work/ready"
wait
SH
chmod +x "$fixture"
sleep 60 &
bystander=$!
start=$SECONDS
run_limited 3 "$fixture" 2>/dev/null
rc=$?
check "the fixture was fully up before the limit" '[[ -s "$work/ready" ]]'
check "a command stopped by its limit returns 124" '(( rc == 124 ))'
check "it stopped soon after the limit" '(( SECONDS - start < 3 + 10 ))'
left() { local p; for p in $(cat "$work/pids"); do alive "$p" && echo "$p"; done; }
for _ in $(seq 20); do [[ -z "$(left)" ]] && break; sleep 0.1; done
check "every recorded member of the group is stopped (grandchildren, pipeline)" '[[ -z "$(left)" ]]'
check "a process outside the group is untouched" 'alive "$bystander"'

# 3. A member that ignores TERM is KILLed after the grace. (Every fixture process ends by itself
#    within 60 s, so a regressed run_limited fails here in about a minute instead of hanging.)
: >"$work/pids"
rm -f "$work/ready"
start=$SECONDS
run_limited 2 bash -c "trap '' TERM; sleep 60 & echo \$! >> '$work/pids'; trap '' TERM; while (( SECONDS < 60 )); do sleep 1; done" 2>/dev/null
rc=$?
for _ in $(seq 20); do [[ -z "$(left)" ]] && break; sleep 0.1; done
check "a TERM-ignoring command is KILLed after the grace (124)" '(( rc == 124 ))'
check "within the limit and the grace, not when it gave up by itself" '(( SECONDS - start < 2 + IOS_LIMIT_GRACE_SECS + 10 ))'
check "its children are gone too" '[[ -z "$(left)" ]]'

kill "$bystander" 2>/dev/null
wait "$bystander" 2>/dev/null
(( failures == 0 )) && echo "run-limited-test: all passed" || { echo "run-limited-test: $failures failed"; exit 1; }
