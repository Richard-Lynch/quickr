#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # rc and start are read inside check's eval strings; g in the trap
# Tests for common.sh run_limited (limit.pl): a command within its limit keeps its status; past
# it, or on TERM, its whole process group stops (grandchildren and a pipeline included, as
# xcodebuild sits under test.sh's watchdog pipeline), a TERM-ignoring member is KILLed after the
# grace, and what a command leaves behind when it exits is stopped too; nothing outside the
# group is touched. Every fixture process ends by itself within 60 s, so a regression fails
# here in about a minute instead of hanging.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
set +e
export IOS_LIMIT_GRACE_SECS=2
failures=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi; }
work="$(mktemp -d "${TMPDIR:-/tmp}/quickr-limit.XXXXXX")"
bystander=""
# What a failing run left behind is stopped here, by the group ids the fixtures recorded.
trap 'for g in $(cat "$work"/group 2>/dev/null); do kill -KILL -- "-$g" 2>/dev/null; done
  [[ -n "$bystander" ]] && kill "$bystander" 2>/dev/null; rm -rf "$work"' EXIT

# Members of the latest fixture's group still running (zombies awaiting their reaper don't count).
members() { ps -axo pgid=,stat= | awk -v g="$(tail -1 "$work/group")" '$1 == g && $2 !~ /^Z/' | wc -l | tr -d ' '; }
settled() { for _ in $(seq 30); do [[ "$(members)" == 0 ]] && return 0; sleep 0.1; done; return 1; }

# A fixture: records its group id (run_limited starts it, so it leads the group), starts a
# three-level tree with a pipeline, says it is ready only once all of it is up, then does `$1`
# (wait, exit, or ignore TERM).
fixture="$work/fixture.sh"
cat >"$fixture" <<SH
#!/usr/bin/env bash
group=\$(ps -o pgid= -p \$\$ | tr -d ' ')
echo "\$group" >> "$work/group"
bash -c 'sleep 60 | cat & wait' &
sleep 60 &
# Up: both sleeps and the pipeline's cat (the bash -c under them is up by then).
until (( \$(ps -axo pgid=,comm= | awk -v g="\$group" '\$1 == g && (\$2 ~ /sleep\$/ || \$2 ~ /cat\$/)' | wc -l) >= 3 )); do sleep 0.1; done
echo ready > "$work/ready"
case "\$1" in
  wait) wait ;;
  exit) exit 0 ;;
  stubborn) trap '' TERM; while (( SECONDS < 60 )); do sleep 1; done ;;
esac
SH
chmod +x "$fixture"
sleep 60 &
bystander=$!

# 1. Within the limit: the command's own status, without waiting for the limit.
start=$SECONDS
run_limited 30 bash -c 'exit 3' 2>/dev/null
rc=$?
check "a command within its limit keeps its status (3)" '(( rc == 3 ))'
check "and returns without waiting for the limit" '(( SECONDS - start < 10 ))'

# 2. Past the limit: the whole group stops; a process outside it doesn't.
start=$SECONDS
run_limited 3 "$fixture" wait 2>/dev/null
rc=$?
check "the fixture was fully up before the limit" '[[ -s "$work/ready" ]]'
check "a command stopped by its limit returns 124" '(( rc == 124 ))'
check "it stopped soon after the limit" '(( SECONDS - start < 3 + 10 ))'
check "nothing of its group is left (grandchildren, the pipeline)" 'settled'
check "a process outside the group is untouched" 'kill -0 "$bystander" 2>/dev/null'

# 3. A command that exits leaving workers behind: its status, and the workers are stopped.
rm -f "$work/ready"
start=$SECONDS
run_limited 30 "$fixture" exit 2>/dev/null
rc=$?
check "a command that exits keeps its status (0)" '(( rc == 0 ))'
check "what it left running is stopped, well before the limit" 'settled && (( SECONDS - start < 15 ))'

# 4. A member that ignores TERM is KILLed after the grace.
rm -f "$work/ready"
start=$SECONDS
run_limited 2 "$fixture" stubborn 2>/dev/null
rc=$?
check "a TERM-ignoring command is KILLed after the grace (124)" '(( rc == 124 ))'
check "within the limit and the grace, not when it gave up by itself" '(( SECONDS - start < 2 + 2 + 10 ))'
check "nothing of that group is left" 'settled'

# 5. TERM to the supervisor stops the group and exits 143.
rm -f "$work/ready"
perl "$here/../limit.pl" 60 "$fixture" wait 2>/dev/null &
supervisor=$!
for _ in $(seq 100); do [[ -s "$work/ready" ]] && break; sleep 0.1; done
kill -TERM "$supervisor"
wait "$supervisor"
rc=$?
check "TERM stops it with 143" '(( rc == 143 ))'
check "and nothing of the group is left" 'settled'

# 6. Under the callers' strict mode (set -euo pipefail from common.sh), a limit is a status:
#    run_limited returns 124 and errexit stops the caller there.
out="$(bash -c "source '$here/../common.sh'; run_limited 1 sleep 30 2>/dev/null; echo unreachable"; echo "rc=$?")"
check "set -e callers see 124 (and stop there)" '[[ "$out" == rc=124 ]]'

kill "$bystander" 2>/dev/null
wait "$bystander" 2>/dev/null
(( failures == 0 )) && echo "run-limited-test: all passed" || { echo "run-limited-test: $failures failed"; exit 1; }
