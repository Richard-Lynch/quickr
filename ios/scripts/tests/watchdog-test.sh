#!/usr/bin/env bash
# Tests for watchdog.sh with fake commands: one that exits, one that falls silent, one that
# hangs after xcodebuild's final line, and one that leaves a helper holding its output open.
set -uo pipefail
wd="$(cd "$(dirname "$0")/.." && pwd)/watchdog.sh"
fails=0
check() {  # check <name> <expected status> <actual status> [output must contain]
  local ok=1
  [[ "$3" == "$2" ]] || ok=0
  [[ -z "${4:-}" || "$out" == *"$4"* ]] || ok=0
  if (( ok )); then echo "ok   $1"; else echo "FAIL $1: status $3 (want $2); output: $out"; fails=$((fails + 1)); fi
}

out="$("$wd" bash -c 'echo one; echo two >&2; exit 3' 2>&1)"; check "passes output and status through" 3 $? "two"

out="$(IOS_WATCHDOG_SILENCE_SECS=2 "$wd" bash -c 'echo started; sleep 30' 2>&1)"
check "kills after silence with 124" 124 $? "watchdog killed bash: no output for 2s"

start=$SECONDS
out="$(IOS_WATCHDOG_GRACE_SECS=2 "$wd" bash -c 'echo "** TEST SUCCEEDED **"; sleep 30' 2>&1)"
check "kills a hang after a SUCCEEDED final line, status 0" 0 $? "after its final line"
(( SECONDS - start < 15 )) || { echo "FAIL grace kill took $((SECONDS - start))s"; fails=$((fails + 1)); }

out="$(IOS_WATCHDOG_GRACE_SECS=2 "$wd" bash -c 'echo "** TEST FAILED **"; sleep 30' 2>&1)"
check "kills a hang after a FAILED final line, status 65" 65 $? "watchdog killed"

out="$(IOS_WATCHDOG_SILENCE_SECS=2 "$wd" bash -c '(sleep 20 &); echo done; exit 0' 2>&1)"
check "a leftover helper holding the pipe doesn't hide a clean exit" 0 $? "done"

out="$("$wd" bash -c 'echo "** TEST SUCCEEDED **"; exit 0' 2>&1)"
check "exits normally right after its final line" 0 $?
[[ "$out" != *watchdog* ]] || { echo "FAIL no watchdog message on a clean exit"; fails=$((fails + 1)); }

(( fails == 0 )) && echo "watchdog: all passed" || { echo "watchdog: $fails failed"; exit 1; }
