#!/usr/bin/env bash
# Runs a command (stdout and stderr merged onto stdout) and kills it when it hangs:
# - no output for IOS_WATCHDOG_SILENCE_MIN minutes (default 10), or
# - it printed xcodebuild's final line ("** TEST SUCCEEDED **", "** BUILD FAILED **", …) and
#   is still running IOS_WATCHDOG_GRACE_SECS seconds later (default 60): xcodebuild sometimes
#   never exits after the tests have finished.
# Exits with the command's own status. When it had to kill: the status the final line reports
# (0 for SUCCEEDED, 65 like xcodebuild for FAILED), or 124 (as timeout(1)) after silence.
# Usage: watchdog.sh <command> [args...]
set -uo pipefail

silence=$(( ${IOS_WATCHDOG_SILENCE_MIN:-10} * 60 ))
grace="${IOS_WATCHDOG_GRACE_SECS:-60}"
# Tests use fractions of a minute.
[[ -n "${IOS_WATCHDOG_SILENCE_SECS:-}" ]] && silence="$IOS_WATCHDOG_SILENCE_SECS"

dir="$(mktemp -d "${TMPDIR:-/tmp}/quickr-watchdog.XXXXXX")"
fifo="$dir/out"
mkfifo "$fifo"
"$@" >"$fifo" 2>&1 &
pid=$!
name="${1##*/}"
exec 3<"$fifo"
rm -rf "$dir"

# Stops the command and everything it started (xcodebuild spawns helpers).
stop() {
  pkill -TERM -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  pkill -KILL -P "$pid" 2>/dev/null
  kill -KILL "$pid" 2>/dev/null
}

# A background job ignores SIGINT, so Ctrl-C (or a CI cancel) has to be passed on.
trap 'stop; exit 130' INT TERM

final=""   # SUCCEEDED or FAILED once the final line was seen
last=$SECONDS
# One-second polls: bash 3.2's `read -t` returns 1 on a timeout, like EOF, so time since the
# last line is tracked here instead.
while true; do
  t0=$SECONDS
  if IFS= read -r -t 1 line <&3; then
    printf '%s\n' "$line"
    last=$SECONDS
    if [[ "$line" =~ \*\*\ [A-Z\ ]*(SUCCEEDED|FAILED)\ \*\* ]]; then
      final="${BASH_REMATCH[1]}"
    fi
    continue
  fi
  [[ -n "${line:-}" ]] && printf '%s' "$line" && last=$SECONDS
  line=""
  # Finished, and the buffered output is drained (a helper it left may still hold the pipe).
  kill -0 "$pid" 2>/dev/null || break
  # EOF while it still runs returns at once: don't spin.
  (( SECONDS == t0 )) && sleep 1
  if [[ -n "$final" ]] && (( SECONDS - last >= grace )); then
    echo "ios: watchdog killed $name: still running ${grace}s after its final line (** … $final **)" >&2
    stop; wait "$pid" 2>/dev/null
    [[ "$final" == SUCCEEDED ]] && exit 0 || exit 65
  fi
  if (( SECONDS - last >= silence )); then
    echo "ios: watchdog killed $name: no output for ${silence}s (IOS_WATCHDOG_SILENCE_MIN)" >&2
    stop; wait "$pid" 2>/dev/null
    exit 124
  fi
done
wait "$pid"
