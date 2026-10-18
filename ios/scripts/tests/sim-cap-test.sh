#!/usr/bin/env bash
# Tests for the simulator cap (common.sh booted_clones/sim_cap) against a fake `xcrun simctl
# list -j devices`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fake="$(mktemp -d "${TMPDIR:-/tmp}/quickr-simcap.XXXXXX")"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/xcrun" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "simctl list -j devices" ]] && exec cat "$FAKE_DEVICES"
exit 1
SH
chmod +x "$fake/xcrun"
devices() {  # devices "<udid>:<state>:<name>" ...
  python3 -c '
import json, sys
print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
    dict(zip(("udid", "state", "name"), d.split(":", 2))) for d in sys.argv[1:]]}}))' "$@" >"$fake/devices.json"
}
export FAKE_DEVICES="$fake/devices.json" PATH="$fake:$PATH" IOS_SIM_WAIT_POLL=1
fails=0
cap() {  # cap <udid>: runs sim_cap in a subshell; sets status and out
  out="$(bash -c 'source "$1/../common.sh"; sim_cap "$2"' _ "$here" "$1" 2>&1)"; status=$?
}
expect() {  # expect <name> <status> [output must contain]
  if [[ "$status" == "$2" && ( -z "${3:-}" || "$out" == *"$3"* ) ]]; then echo "ok   $1"
  else echo "FAIL $1: status $status (want $2): $out"; fails=$((fails + 1)); fi
}

A="quickR iOS-26-0 ios-m2-form-f74fa0"; B="quickR iOS-26-0 ios-m1-skel-0a1b2c"; C="quickR iOS-26-0 ios-m1-data-123abc"
devices "a:Booted:$A" "b:Shutdown:$B" "m:Booted:quickR iOS-26-0" "x:Booted:iPhone 17"
cap c; expect "one clone booted: a slot is free (non-clones don't count)" 0

devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
cap c; expect "two clones booted: refused, naming them" 1 "ios-m1-skel-0a1b2c"
[[ "$out" == *"ios-m2-form-f74fa0"* ]] || { echo "FAIL the message names every booted clone"; fails=$((fails + 1)); }
cap a; expect "re-booting your own booted clone doesn't count against you" 0
IOS_SIM_CAP=3 cap c; expect "IOS_SIM_CAP raises the cap" 0
IOS_SIM_CAP=0 cap c; expect "IOS_SIM_CAP=0 turns it off" 0

# --wait: a slot frees while it polls.
( sleep 2; devices "a:Booted:$A" "b:Shutdown:$B" "c:Shutdown:$C" ) &
start=$SECONDS
IOS_SIM_WAIT=1 cap c; expect "IOS_SIM_WAIT waits until a slot frees" 0 "waiting for a simulator slot"
(( SECONDS - start >= 2 )) || { echo "FAIL it returned before the slot freed"; fails=$((fails + 1)); }
wait

(( fails == 0 )) && echo "sim cap: all passed" || { echo "sim cap: $fails failed"; exit 1; }
