#!/usr/bin/env bash
# Tests for watchdog.sh with fake commands.
set -uo pipefail
wd="$(cd "$(dirname "$0")/.." && pwd)/watchdog.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickr-wdtest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() {  # check <name> <expected status> <actual status> [output must contain]
  if [[ "$3" == "$2" && ( -z "${4:-}" || "$out" == *"$4"* ) ]]; then echo "ok   $1"
  else fail "$1: status $3 (want $2); output: $out"; fi
}
alive() { kill -0 "$(cat "$1")" 2>/dev/null; }

out="$("$wd" bash -c 'echo one; echo two >&2; exit 3' 2>&1)"; check "passes output and status through" 3 $? "two"

out="$("$wd" bash -c 'printf "no newline at the end"' 2>&1)"
check "keeps a last line without a newline" 0 $? "no newline at the end"

out="$(IOS_WATCHDOG_SILENCE_SECS=3 "$wd" bash -c 'echo started; sleep 30' 2>&1)"
check "kills after silence with 124" 124 $? "watchdog killed bash: no output for 3s"

# A partial line is output too: dots every second, never a newline, for 6 s.
out="$(IOS_WATCHDOG_SILENCE_SECS=3 "$wd" bash -c 'for i in 1 2 3 4 5 6; do printf .; sleep 1; done; echo end' 2>&1)"
check "partial-line progress counts as activity" 0 $? "......end"

# ...and a partial line followed by silence is still silence.
out="$(IOS_WATCHDOG_SILENCE_SECS=3 "$wd" bash -c 'printf "Resolving pack"; sleep 30' 2>&1)"
check "a partial line, then silence, is killed (and the partial line shown)" 124 $? "Resolving pack"

start=$SECONDS
out="$(IOS_WATCHDOG_GRACE_SECS=2 "$wd" bash -c 'echo "** TEST SUCCEEDED **"; sleep 30' 2>&1)"
check "kills a hang after a SUCCEEDED final line, status 0" 0 $? "after its final line"
(( SECONDS - start < 15 )) || fail "the grace kill took $((SECONDS - start))s"

out="$(IOS_WATCHDOG_GRACE_SECS=2 "$wd" bash -c 'echo "** TEST FAILED **"; sleep 30' 2>&1)"
check "kills a hang after a FAILED final line, status 65" 65 $? "watchdog killed"

# A final line that arrives in three pieces, each in its own poll, still counts.
out="$(IOS_WATCHDOG_GRACE_SECS=2 IOS_WATCHDOG_POLL_SECS=0.5 "$wd" bash -c \
  'printf "** TEST "; sleep 1.2; printf "SUCC"; sleep 1.2; printf "EEDED **\n"; sleep 30' 2>&1)"
check "a final line split across three polls is found" 0 $? "after its final line"

# Output after the final line doesn't move its deadline.
start=$SECONDS
out="$(IOS_WATCHDOG_GRACE_SECS=3 "$wd" bash -c 'echo "** TEST SUCCEEDED **"; while :; do echo diag; sleep 1; done' 2>&1)"
check "output after the final line doesn't extend its deadline" 0 $? "after its final line"
(( SECONDS - start < 15 )) || fail "chatter after the final line kept it alive $((SECONDS - start))s"

# The whole process group goes: a grandchild that outlives its parent, on a normal exit...
out="$("$wd" bash -c '(bash -c "echo \$\$ > '"$tmp"'/gc1; exec sleep 60") & sleep 1; echo done' 2>&1)"
check "a clean exit returns at once despite a leftover helper" 0 $? "done"
sleep 1
alive "$tmp/gc1" && fail "a grandchild survived the command's normal exit"

# ...and when the watchdog kills, even a grandchild that ignores TERM.
out="$(IOS_WATCHDOG_SILENCE_SECS=2 "$wd" bash -c '(trap "" TERM; bash -c "trap \"\" TERM; echo \$\$ > '"$tmp"'/gc2; sleep 60") & sleep 60' 2>&1)"
check "kills after silence with a TERM-ignoring grandchild" 124 $?
sleep 1
alive "$tmp/gc2" && fail "a TERM-ignoring grandchild survived the kill"

# A TERM to the watchdog is passed on and gives 143.
"$wd" bash -c 'echo $$ > '"$tmp"'/child; sleep 60' >/dev/null 2>&1 &
w=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$tmp/child" ]] && break; sleep 0.5; done
kill -TERM "$w"; wait "$w"; status=$?
out=""; check "TERM gives 143" 143 "$status"
sleep 1
alive "$tmp/child" && fail "the command survived a TERM to the watchdog"

out="$(IOS_WATCHDOG=0 IOS_WATCHDOG_SILENCE_SECS=1 "$wd" bash -c 'sleep 2; echo plain; exit 4' 2>&1)"
check "IOS_WATCHDOG=0 runs it plainly" 4 $? "plain"

out="$("$wd" bash -c 'echo "** TEST SUCCEEDED **"; exit 0' 2>&1)"
check "exits normally right after its final line" 0 $?
[[ "$out" != *watchdog* ]] || fail "a watchdog message on a clean exit"

# Streaming: a line shows up downstream within about 2 s while the command is still running.
# shows <file> <text> <pid>: waits up to 2.5 s for <text> in <file>; fails if it doesn't come
# or <pid> (the command) is already gone.
shows() {
  local i
  for i in 1 2 3 4 5; do
    sleep 0.5
    if grep -q "$2" "$1" 2>/dev/null; then kill -0 "$3" 2>/dev/null; return; fi
  done
  return 1
}
lb="$(cd "$(dirname "$0")/.." && pwd)/linebuffered.py"
"$wd" bash -c 'echo first-line; sleep 8' >"$tmp/raw.out" 2>&1 &
p=$!
shows "$tmp/raw.out" first-line "$p" && echo "ok   the watchdog streams a line within 2 s" \
  || fail "the watchdog held a line back: $(cat "$tmp/raw.out")"
wait "$p"

# A program that block-buffers a pipe (as xcbeautify does) streams through linebuffered.py.
buffered='import sys, time
for line in sys.stdin:
    print("seen " + line, end="")'
"$wd" bash -c 'echo first-line; sleep 8' | "$lb" python3 -c "$buffered" >"$tmp/lb.out" 2>&1 &
p=$!
shows "$tmp/lb.out" "seen first-line" "$p" && echo "ok   a block-buffering filter streams through linebuffered.py" \
  || fail "linebuffered.py held a line back: $(cat "$tmp/lb.out")"
wait "$p"
"$wd" bash -c 'echo first-line; sleep 4' | python3 -c "$buffered" >"$tmp/nolb.out" 2>&1 &
p=$!
shows "$tmp/nolb.out" "seen first-line" "$p" && fail "the control should have buffered (the test proves nothing)" \
  || echo "ok   (control: without it the same filter holds the line back)"
wait "$p"

if command -v xcbeautify >/dev/null; then
  "$wd" bash -c "echo \"Test Case '-[QuickRTests.T testA]' passed (0.100 seconds).\"; sleep 8" \
    | "$lb" xcbeautify >"$tmp/xcb.out" 2>&1 &
  p=$!
  shows "$tmp/xcb.out" testA "$p" && echo "ok   xcbeautify's lines stream within 2 s" \
    || fail "xcbeautify held a line back: $(cat "$tmp/xcb.out")"
  wait "$p"
fi

out="$(echo hi | "$lb" bash -c 'cat; exit 5' 2>&1)"
check "linebuffered.py keeps plain newlines and the exit status" 5 $? "hi"
[[ "$out" != *$'\r'* ]] || fail "linebuffered.py turned newlines into CRLF"

# linebuffered.py passes INT and TERM on, reaps the command and exits 128 + N.
# lbsig <signal> <child script> <name>: starts linebuffered.py, signals it once the child
# wrote its pid, then sets status and checks the child is gone.
lbsig() {
  rm -f "$tmp/lbchild"
  "$lb" bash -c "echo \$\$ > $tmp/lbchild; $2" </dev/null >/dev/null 2>&1 &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$tmp/lbchild" ]] && break; sleep 0.3; done
  kill "-$1" "$w"; wait "$w"; status=$?
  sleep 0.5
  alive "$tmp/lbchild" && fail "$3: the command survived"
}
lbsig TERM "exec sleep 60" "TERM"; out=""; check "linebuffered.py: TERM reaches the command, exit 143" 143 "$status"
lbsig INT "exec sleep 60" "INT"; out=""; check "linebuffered.py: INT reaches the command, exit 130" 130 "$status"
start=$SECONDS
lbsig TERM 'trap "" TERM; sleep 60' "TERM-ignoring"
out=""; check "linebuffered.py: a command ignoring TERM is killed after 5 s" 137 "$status"
(( SECONDS - start < 15 )) || fail "the TERM-ignoring command took $((SECONDS - start))s to go"
out="$("$lb" bash -c 'kill -TERM $$' 2>&1)"
check "linebuffered.py: a command ended by a signal gives 128 + N" 143 $?

out="$(IOS_WATCHDOG_HEARTBEAT_SECS=2 "$wd" bash -c 'printf 12345; sleep 5' 2>&1)"
check "a heartbeat while it runs" 0 $? "ios: still running bash:"
[[ "$out" == *"KB of output, last output"* ]] || fail "the heartbeat names output and last activity: $out"

(( fails == 0 )) && echo "watchdog: all passed" || { echo "watchdog: $fails failed"; exit 1; }
