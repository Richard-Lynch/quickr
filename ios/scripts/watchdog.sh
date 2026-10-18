#!/usr/bin/env bash
# Runs a command (stdout and stderr merged onto stdout) and kills it when it hangs:
# - no output at all, not even part of a line, for IOS_WATCHDOG_SILENCE_MIN minutes
#   (default 20); call sites with long silent phases (package resolution) raise it, or
# - it printed xcodebuild's final line ("** TEST SUCCEEDED **", "** BUILD FAILED **", …) and
#   is still running IOS_WATCHDOG_GRACE_SECS seconds later (default 60), whatever it prints
#   after: xcodebuild sometimes never exits once the tests have finished.
# IOS_WATCHDOG=0 runs the command plainly.
#
# The output goes to a file that is copied to stdout by byte offset, so activity is measured
# in bytes (a partial line counts) and nothing depends on `read -t`, which on macOS bash 3.2
# drops partial lines and reports a timeout like EOF.
#
# The command runs in its own process group (stdin from /dev/null). When it exits, or is
# killed, the whole group is ended (TERM, then KILL), so no helper it started outlives it.
# Simulators are not in the group (CoreSimulator, under launchd, runs them) and are left alone.
#
# Exits with the command's own status. When it had to kill: the status the final line reports
# (0 for SUCCEEDED, 65 like xcodebuild for FAILED), or 124 (as timeout(1)) after silence.
# Interrupted: 130 (INT) or 143 (TERM), after passing that signal on.
# Usage: watchdog.sh <command> [args...]
set -uo pipefail

if [[ "${IOS_WATCHDOG:-1}" == 0 ]]; then
  exec "$@" 2>&1
fi

silence=$(( ${IOS_WATCHDOG_SILENCE_MIN:-20} * 60 ))
# Tests use seconds.
[[ -n "${IOS_WATCHDOG_SILENCE_SECS:-}" ]] && silence="$IOS_WATCHDOG_SILENCE_SECS"
grace="${IOS_WATCHDOG_GRACE_SECS:-60}"
poll="${IOS_WATCHDOG_POLL_SECS:-1}"
name="${1##*/}"
command -v perl >/dev/null || { echo "ios: watchdog needs perl (to give the command its own process group)" >&2; exit 127; }

dir="$(mktemp -d "${TMPDIR:-/tmp}/quickr-watchdog.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
log="$dir/log"
: >"$log"
# setpgrp(0, 0): a process group of its own, whose id is the command's pid.
perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "watchdog: cannot run $ARGV[0]: $!\n"' "$@" \
  </dev/null >"$log" 2>&1 &
pid=$!

# Ends the command's whole process group, if anything of it is left: the signal, then KILL
# after 5 s.
stop_group() {
  kill "-${1:-TERM}" -- "-$pid" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL -- "-$pid" 2>/dev/null
  return 0
}

sent=0        # bytes of the log already copied to stdout
final=""      # SUCCEEDED or FAILED once the final line was seen
final_at=0
# The last 120 bytes seen so far (longer than any final line), so a final line split across
# any number of polls is still found.
carry=""
# Copies what the log gained since the last call to stdout and looks for the final line in it.
# Fails when nothing new arrived.
pump() {
  local size chunk="$dir/chunk" match
  size=$(wc -c <"$log" | tr -d ' ')
  (( size > sent )) || return 1
  tail -c "+$((sent + 1))" "$log" | head -c "$((size - sent))" >"$chunk"
  cat "$chunk"
  sent=$size
  if [[ -z "$final" ]]; then
    match="$( { printf '%s' "$carry"; cat "$chunk"; } | grep -Eo '\*\* [A-Z ]*(SUCCEEDED|FAILED) \*\*' | tail -1)"
    if [[ -n "$match" ]]; then
      [[ "$match" == *SUCCEEDED* ]] && final=SUCCEEDED || final=FAILED
      final_at=$SECONDS
    fi
  fi
  carry="$( { printf '%s' "$carry"; cat "$chunk"; } | tail -c 120)"
  return 0
}

# Copies the rest of the output, ends the group, reaps the command and exits with $1.
finish() {
  pump || true
  stop_group TERM
  wait "$pid" 2>/dev/null
  rm -rf "$dir"
  exit "$1"
}

# A background job ignores SIGINT, so a Ctrl-C (or a CI cancel's TERM) is passed on.
trap 'stop_group INT; finish 130' INT
trap 'stop_group TERM; finish 143' TERM

last=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
  sleep "$poll"
  pump && last=$SECONDS
  kill -0 "$pid" 2>/dev/null || break
  # The final line's deadline holds even while output continues.
  if [[ -n "$final" ]] && (( SECONDS - final_at >= grace )); then
    echo "ios: watchdog killed $name: still running ${grace}s after its final line (** … $final **)" >&2
    [[ "$final" == SUCCEEDED ]] && finish 0 || finish 65
  fi
  if (( SECONDS - last >= silence )); then
    echo "ios: watchdog killed $name: no output for ${silence}s (IOS_WATCHDOG_SILENCE_MIN)" >&2
    finish 124
  fi
done
wait "$pid"
status=$?
# Anything it left running in its group goes with it.
finish "$status"
