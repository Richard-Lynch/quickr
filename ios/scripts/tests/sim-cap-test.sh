#!/usr/bin/env bash
# Tests for simulator admission (common.sh booted_clones/sim_boot) and the make targets' default
# device (target_sim_udid) against a fake `xcrun simctl`: `list [-j] devices [available]` serves
# a JSON file (or its text form), `bootstatus <udid> -b` marks the device booted after
# FAKE_BOOT_SECS (default 1), like a real boot taking a while, and `clone` adds a device.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fake="$(mktemp -d "${TMPDIR:-/tmp}/quickr-simcap.XXXXXX")"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/xcrun" <<'SH'
#!/usr/bin/env bash
case "$*" in
"simctl list -j devices" | "simctl list -j devices available")
  [[ "${FAKE_LIST_FAIL:-0}" == 1 ]] && exit 1
  exec cat "$FAKE_DEVICES" ;;
"simctl list devices" | "simctl list devices available")
  exec python3 -c '
import json, sys
for runtime, ds in json.load(open(sys.argv[1]))["devices"].items():
    print("-- " + runtime + " --")
    for d in ds:
        print("    %s (%s) (%s)" % (d["name"], d["udid"], d["state"]))' "$FAKE_DEVICES" ;;
"simctl clone "*)
  exec python3 - "$FAKE_DEVICES" "$3" "$4" <<'PY'
import json, os, sys, uuid
path, src, name = sys.argv[1:]
data = json.load(open(path))
for devices in data["devices"].values():
    for d in list(devices):
        if d["udid"] == src:
            new = dict(d, udid=str(uuid.uuid4()).upper(), name=name, state="Shutdown")
            devices.append(new)
            print(new["udid"])
json.dump(data, open(path + ".tmp", "w"))
os.replace(path + ".tmp", path)
PY
  ;;
"simctl shutdown "*)
  echo "$3" >>"$FAKE_DEVICES.shutdowns"
  [[ "${FAKE_SHUTDOWN_FAIL:-0}" == 1 ]] && exit 1
  exec python3 - "$FAKE_DEVICES" "$3" <<'PY'
import json, os, sys
path, udid = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for devices in data["devices"].values():
    for d in devices:
        if d["udid"] == udid:
            d["state"] = "Shutdown"
tmp = path + ".tmp"
json.dump(data, open(tmp, "w"))
os.replace(tmp, path)
PY
  ;;
"simctl bootstatus "*" -b")
  sleep "${FAKE_BOOT_SECS:-1}"
  exec python3 - "$FAKE_DEVICES" "$3" <<'PY'
import json, os, sys
path, udid = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for devices in data["devices"].values():
    for d in devices:
        if d["udid"] == udid:
            d["state"] = "Booted"
tmp = path + ".tmp"
json.dump(data, open(tmp, "w"))
os.replace(tmp, path)
PY
  ;;
esac
exit 1
SH
chmod +x "$fake/xcrun"
printf '#!/bin/sh\n[ "$1" = -version ] && echo "Xcode 27.1"\n' >"$fake/xcodebuild"  # require_xcodebuild
chmod +x "$fake/xcodebuild"
devices() {  # devices "<udid>:<state>:<name>" ...
  python3 -c '
import json, sys
print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
    dict(zip(("udid", "state", "name"), d.split(":", 2)), deviceTypeIdentifier="iPhone-17")
    for d in sys.argv[1:]]}}))' "$@" >"$fake/devices.new"
  mv "$fake/devices.new" "$fake/devices.json"  # atomic: a background rewrite races readers
}
state() {  # state <udid>
  python3 -c '
import json, sys
for ds in json.load(open(sys.argv[1]))["devices"].values():
    for d in ds:
        if d["udid"] == sys.argv[2]: print(d["state"])' "$fake/devices.json" "$1"
}
export FAKE_DEVICES="$fake/devices.json" PATH="$fake:$PATH" IOS_SIM_WAIT_POLL=1
export QUICKR_SIM_CAP_LOCK="$fake/cap.lockf" QUICKR_SIM_CLONE_LOCK="$fake/clone.lockf"
export QUICKR_SIM_CAP_QUEUE="$fake/queue" QUICKR_SIM_HOLDS="$fake/holds"
# The caller's settings must not leak in: an inherited IOS_SIM_WAIT=1 (check-ios run with it)
# turns the "refused" cases into waits that never end.
unset IOS_SIM_WAIT IOS_SIM_CAP CI IOS_SIM_DEFAULTED IOS_SIM IOS_SIM_MIN IOS_SIM_KEEP  # CI skips the cap in sim_boot
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
boot() {  # boot <udid>: sim_boot in a subshell; sets status and out
  # Bounded: a regression that never admits fails here (status 142) instead of hanging the suite.
  out="$(perl -e 'alarm shift; exec @ARGV' 120 bash -c 'source "$1/../common.sh"; sim_boot "$2"' _ "$here" "$1" 2>&1)"; status=$?
}
expect() {  # expect <name> <status> [output must contain]
  if [[ "$status" == "$2" && ( -z "${3:-}" || "$out" == *"$3"* ) ]]; then echo "ok   $1"
  else fail "$1: status $status (want $2): $out"; fi
}

A="quickR iOS-26-0 ios-m2-form-f74fa0"; B="quickR iOS-26-0 ios-m1-skel-0a1b2c"
C="quickR iOS-26-0 ios-m1-data-123abc"; D="quickR iOS-26-0 ios-m1-sync-456def"

devices "a:Booted:$A" "b:Shutdown:$B" "c:Shutdown:$C" "x:Booted:iPhone 17"
boot c; expect "one clone booted: a slot is free (non-quickR devices don't count), and it boots" 0
[[ "$(state c)" == Booted ]] || fail "the admitted clone was not booted"

# The shared base device counts like a clone (a plain `make ios-test` used to boot it uncapped).
devices "m:Booted:quickR iOS-26-0" "c:Shutdown:$C"
boot c; expect "a booted base device counts, leaving one slot" 0
devices "m:Booted:quickR iOS-26-0" "a:Booted:$A" "c:Shutdown:$C"
boot c; expect "the base device and one clone booted: a third is refused at cap 2" 1 "quickR iOS-26-0"
[[ "$(state c)" == Shutdown ]] || fail "a clone refused because of the base device was booted"
devices "m:Booted:quickR iOS-26-0" "a:Booted:$A" "b:Booted:$B"
boot m; expect "the base device re-booting itself is fine" 0
devices "m:Shutdown:quickR iOS27" "a:Booted:$A" "b:Booted:$B"
boot m; expect "a shut-down base device is refused at the cap like a clone" 1

devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
boot c; expect "two clones booted: refused, naming them" 1 "ios-m1-skel-0a1b2c"
[[ "$out" == *"ios-m2-form-f74fa0"* ]] || fail "the message names every booted clone"
[[ "$(state c)" == Shutdown ]] || fail "a refused clone was booted"
boot a; expect "your own booted clone doesn't count against you" 0
IOS_SIM_CAP=3 boot c; expect "IOS_SIM_CAP raises the cap" 0
devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
IOS_SIM_CAP=0 boot c; expect "IOS_SIM_CAP=0 turns it off" 0

# --wait: a slot frees while it polls.
devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
( sleep 2; devices "a:Booted:$A" "b:Shutdown:$B" "c:Shutdown:$C" ) &
start=$SECONDS
IOS_SIM_WAIT=1 boot c; expect "IOS_SIM_WAIT waits until a slot frees" 0 "waiting for a simulator slot"
(( SECONDS - start >= 2 )) || fail "it returned before the slot freed"
wait

# A race: one slot left, two worktrees admit at once. Exactly one boots, the other is refused.
devices "a:Booted:$A" "c:Shutdown:$C" "d:Shutdown:$D"
FAKE_BOOT_SECS=2 bash -c 'source "$1/../common.sh"; sim_boot c' _ "$here" >"$fake/c.out" 2>&1 &
pc=$!
FAKE_BOOT_SECS=2 bash -c 'source "$1/../common.sh"; sim_boot d' _ "$here" >"$fake/d.out" 2>&1 &
pd=$!
wait "$pc"; sc=$?
wait "$pd"; sd=$?
booted_count=$(( $([[ "$(state c)" == Booted ]] && echo 1 || echo 0) + $([[ "$(state d)" == Booted ]] && echo 1 || echo 0) ))
if (( booted_count == 1 && sc + sd == 1 )); then echo "ok   two concurrent admissions for the last slot: one boots, one is refused"
else fail "concurrent admissions: c=$sc ($(state c)), d=$sd ($(state d)); $(cat "$fake/c.out" "$fake/d.out")"; fi

# The make targets' device: this worktree's clone unless one was set (or under CI).
BASE=11111111-2222-3333-4444-555555555555
resolve() {  # resolve <name> [VAR=value ...]: target_sim_udid in a subshell; sets status and out
  local name="$1"; shift
  out="$(env "$@" bash -c 'source "$1/../common.sh"; target_sim_udid "$2"' _ "$here" "$name" 2>/dev/null)"; status=$?
}
root_real="$(cd "$here/../../.." && pwd -P)"
mine="quickR iOS-26-0 $(basename "$root_real")-$(printf '%s' "$root_real" | shasum | cut -c1-6)"
devices "$BASE:Shutdown:quickR iOS-26-0"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=0; expect "an explicit device is used as given" 0 "$BASE"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=1 CI=true; expect "under CI the defaulted device is used as given" 0 "$BASE"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=1; clone="$out"
expect "a defaulted device becomes this worktree's clone" 0
[[ "$clone" =~ ^[0-9A-F-]{36}$ && "$clone" != "$BASE" ]] || fail "the default is not a new clone: $clone"
grep -qF "$mine" "$fake/devices.json" || fail "the clone is not named '$mine'"
[[ "$(state "$clone")" == Shutdown ]] || fail "resolving the default booted the clone"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=1
[[ "$out" == "$clone" ]] && echo "ok   the default resolves to the same clone again" || fail "a second clone: $out"
resolve "$clone" IOS_SIM_DEFAULTED=1; expect "a UDID is used as given, never cloned again" 0 "$clone"
(( $(grep -o '"udid"' "$fake/devices.json" | wc -l) == 2 )) || fail "resolving a UDID created a device"

# The Makefile marks a target's device defaulted when the variable that target uses wasn't set:
# ios-test IOS_SIM_MIN (IOS_SIM isn't its device), ios-uitest and ios-sim-run IOS_SIM (or
# IOS_SIM_MIN, its default), check-ios IOS_SIM_MIN and IOS_SIM_CUR for its two runtimes.
# Nested makes inherit command-line overrides through MAKEFLAGS (`make ios-script-test
# IOS_SIM_MIN=x`), so those are cleared too.
mk() {  # mk [VAR=value ...] -- <make args>: the script line make would run
  local vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  env -u IOS_SIM -u IOS_SIM_MIN -u IOS_SIM_CUR -u MAKEFLAGS -u MAKEOVERRIDES -u MFLAGS -u MAKELEVEL \
    ${vars[@]+"${vars[@]}"} make -s -n -C "$root_real" "$@" 2>/dev/null \
    | grep -E 'test\.sh|sim-run\.sh|check-ios\.sh'
}
for c in "ios-test|IOS_SIM_DEFAULTED=1" "ios-test IOS_SIM_MIN=x|IOS_SIM_DEFAULTED=0" \
  "ios-test IOS_SIM=x|IOS_SIM_DEFAULTED=1" "ios-uitest|IOS_SIM_DEFAULTED=1" \
  "ios-uitest IOS_SIM=x|IOS_SIM_DEFAULTED=0" "ios-uitest IOS_SIM_MIN=x|IOS_SIM_DEFAULTED=0" \
  "ios-sim-run|IOS_SIM_DEFAULTED=1" "ios-sim-run IOS_SIM=x|IOS_SIM_DEFAULTED=0" \
  "check-ios|IOS_SIM_MIN_DEFAULTED=1 IOS_SIM_CUR_DEFAULTED=1" \
  "check-ios IOS_SIM_MIN=x|IOS_SIM_MIN_DEFAULTED=0 IOS_SIM_CUR_DEFAULTED=1" \
  "check-ios IOS_SIM_CUR=x|IOS_SIM_MIN_DEFAULTED=1 IOS_SIM_CUR_DEFAULTED=0"; do
  args="${c%%|*}"; want="${c#*|}"
  # shellcheck disable=SC2086 # split on purpose: target and variables
  got="$(mk -- $args)"
  [[ "$got" == "$want "* ]] && echo "ok   make $args: $want" || fail "make $args: '$got' (want $want)"
done
got="$(mk IOS_SIM_MIN=x -- ios-test)"
[[ "$got" == "IOS_SIM_DEFAULTED=0 "* ]] && echo "ok   IOS_SIM_MIN from the environment counts as set" || fail "env IOS_SIM_MIN: $got"
got="$(MAKEFLAGS=" -- IOS_SIM_MIN=x" MAKEOVERRIDES="IOS_SIM_MIN=x" mk -- ios-test)"
[[ "$got" == "IOS_SIM_DEFAULTED=1 "* ]] && echo "ok   an outer make's overrides don't leak into these" || fail "leaked override: $got"

# FIFO admission (tickets in QUICKR_SIM_CAP_QUEUE).
setstate() {  # setstate <udid> <state>: one device, the others untouched (atomic rewrite)
  python3 - "$fake/devices.json" "$1" "$2" <<'PY'
import json, os, sys
path, udid, new = sys.argv[1:]
data = json.load(open(path))
for devices in data["devices"].values():
    for d in devices:
        if d["udid"] == udid:
            d["state"] = new
json.dump(data, open(path + ".tmp", "w"))
os.replace(path + ".tmp", path)
PY
}
tickets() { ls "$QUICKR_SIM_CAP_QUEUE" 2>/dev/null | grep -c '^[0-9]*\.[0-9]*$'; }
tickets_are() { [[ "$(tickets)" == "$1" ]]; }  # evaluated at each poll
until_true() {  # until_true <what> <command...>: polls for up to 30 s
  local what="$1"; shift
  for _ in $(seq 1 300); do "$@" && return 0; sleep 0.1; done
  fail "timed out waiting until $what"; return 1
}
started() { ps -o lstart= -p "$1" | tr -s ' '; }
gone() { ! kill -0 "$1" 2>/dev/null; }
# Bounded: a waiter that never returns fails the test (and is killed) instead of hanging it.
reap() {  # reap <pid>: waits up to 30 s for it to end; sets reaped to its status
  until_true "pid $1 ends" gone "$1" || kill -KILL "$1" 2>/dev/null
  wait "$1"; reaped=$?
}
rm -rf "$QUICKR_SIM_CAP_QUEUE"

# Order: with one slot (taken by a), c queues first, then d; when a's slot frees, c gets it,
# not whichever polls first; d gets the next.
devices "a:Booted:$A" "c:Shutdown:$C" "d:Shutdown:$D"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'source "$1/../common.sh"; sim_boot c' _ "$here" >"$fake/fc.out" 2>&1 &
pc=$!
until_true "c has a ticket" tickets_are 1
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'source "$1/../common.sh"; sim_boot d' _ "$here" >"$fake/fd.out" 2>&1 &
pd=$!
until_true "d has a ticket" tickets_are 2
until_true "d says where it is" grep -q "place 2 in the queue" "$fake/fd.out"
grep -q "place 1 in the queue" "$fake/fc.out" && echo "ok   the first waiter is told it is first" || fail "c's place: $(cat "$fake/fc.out")"
setstate a Shutdown
reap "$pc"; sc=$reaped
[[ "$sc" == 0 && "$(state c)" == Booted && "$(state d)" == Shutdown ]] \
  && echo "ok   the freed slot goes to the first waiter" || fail "order: c=$sc $(state c), d=$(state d)"
kill -0 "$pd" 2>/dev/null && echo "ok   the second keeps waiting while the slot is taken" || fail "d stopped waiting"
setstate c Shutdown
reap "$pd"; sd=$reaped
[[ "$sd" == 0 && "$(state d)" == Booted ]] && echo "ok   then the second gets it" || fail "d=$sd $(state d)"
[[ "$(tickets)" == 0 ]] && echo "ok   admitted waiters leave no ticket" || fail "tickets left: $(ls "$QUICKR_SIM_CAP_QUEUE")"

# A dead waiter's ticket (its pid gone, or reused by another process) holds nobody up.
mkdir -p "$QUICKR_SIM_CAP_QUEUE"
sleep 0 & dead=$!; wait "$dead"
echo "Mon Jan  1 00:00:00 2001" >"$QUICKR_SIM_CAP_QUEUE/000000000000.$dead"
echo "Mon Jan  1 00:00:00 2001" >"$QUICKR_SIM_CAP_QUEUE/000000000001.$$"  # a live pid, another start time
devices "c:Shutdown:$C"
IOS_SIM_CAP=1 boot c; expect "a dead waiter's ticket is skipped and removed" 0
[[ "$(tickets)" == 0 ]] || fail "dead tickets left: $(ls "$QUICKR_SIM_CAP_QUEUE")"

# A live waiter ahead: a newcomer that won't wait is refused even with a slot free; cap 0
# ignores the queue; re-booting a booted device never queues.
started $$ >"$QUICKR_SIM_CAP_QUEUE/000000000002.$$"
devices "c:Shutdown:$C" "d:Booted:$D"
IOS_SIM_CAP=3 boot c; expect "a free slot still goes to the waiter ahead" 1 "1 waiting ahead"
[[ "$(state c)" == Shutdown ]] || fail "c jumped the queue"
IOS_SIM_CAP=0 boot c; expect "IOS_SIM_CAP=0 ignores the queue" 0
IOS_SIM_CAP=3 boot d; expect "a booted device re-booting never queues" 0
rm -f "$QUICKR_SIM_CAP_QUEUE/000000000002.$$"

# A waiter stopped by TERM drops its ticket at once, and the caller's EXIT trap still runs, seeing
# the real status (143).
devices "a:Booted:$A" "c:Shutdown:$C"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'trap "echo caller-trap-ran rc=\$?; false; echo errexit-lost" EXIT; source "$1/../common.sh"; sim_boot c' _ "$here" >"$fake/fe.out" 2>&1 &
pe=$!
until_true "the waiter has a ticket" tickets_are 1
kill -TERM "$pe"; reap "$pe"
[[ "$(tickets)" == 0 ]] && echo "ok   a stopped waiter's ticket is dropped at once" || fail "ticket left after TERM"
grep -q "caller-trap-ran rc=143" "$fake/fe.out" && echo "ok   the caller's EXIT trap still runs, with the real status" \
  || fail "caller trap: $(cat "$fake/fe.out")"
# (Its handler's `false`, under errexit, then ends the process with 1, as it would without us.)
[[ "$reaped" == 1 ]] && echo "ok   the waiter's status is the caller's handler's" || fail "status $reaped"
grep -q errexit-lost "$fake/fe.out" && fail "the caller's EXIT handler ran without errexit" \
  || echo "ok   the caller's EXIT handler keeps errexit (common.sh's set -e)"

# A caller that ignores TERM: it stays ignored while waiting (the waiter keeps its place) and
# after admission.
devices "a:Booted:$A" "c:Shutdown:$C"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 perl -e 'alarm shift; exec @ARGV' 120 \
  bash -c 'trap "" TERM; source "$1/../common.sh"; sim_boot c; trap -p >"$2"' _ "$here" "$fake/ign.traps" >/dev/null 2>&1 &
pi=$!
until_true "the ignoring waiter has a ticket" tickets_are 1
kill -TERM "$pi" 2>/dev/null; sleep 1
! gone "$pi" && [[ "$(tickets)" == 1 ]] && echo "ok   an ignored TERM stays ignored while waiting" || fail "TERM wasn't ignored"
setstate a Shutdown
reap "$pi"
[[ "$reaped" == 0 && "$(cat "$fake/ign.traps")" == "trap -- '' SIGTERM" ]] \
  && echo "ok   and still ignored once admitted" || fail "after admission: $reaped $(cat "$fake/ign.traps")"

# Admitted after waiting: the caller's own traps are back, unchanged.
devices "a:Booted:$A" "c:Shutdown:$C"
( sleep 2; setstate a Shutdown ) &
# (`trap -p` straight into a file: in a pipeline or `$(…)` it would run in a subshell, which has
# no traps.)
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 perl -e 'alarm shift; exec @ARGV' 120 \
  bash -c 'trap "echo mine" INT; source "$1/../common.sh"; sim_boot c; trap -p >"$2"' _ "$here" "$fake/traps.out" \
  >/dev/null 2>&1
wait
traps="$(cat "$fake/traps.out")"
[[ "$traps" == "trap -- 'echo mine' SIGINT" ]] \
  && echo "ok   once admitted, the caller's traps are as they were (no EXIT, TERM or HUP of its own)" \
  || fail "traps after admission: $traps"

# A caller with an empty EXIT trap (`trap '' EXIT`): waiting and exiting still work, and the empty
# trap is back once admitted.
devices "a:Booted:$A" "c:Shutdown:$C"
( sleep 2; setstate a Shutdown ) &
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 perl -e 'alarm shift; exec @ARGV' 120 \
  bash -c 'trap "" EXIT; source "$1/../common.sh"; sim_boot c; trap -p EXIT >"$2"' _ "$here" "$fake/empty.traps" \
  >"$fake/empty.out" 2>&1
rc=$?
wait
[[ "$rc" == 0 && "$(cat "$fake/empty.traps")" == "trap -- '' EXIT" && "$(tickets)" == 0 ]] \
  && echo "ok   an empty EXIT trap is kept and works" || fail "empty EXIT trap: rc=$rc $(cat "$fake/empty.traps") $(cat "$fake/empty.out")"
devices "a:Booted:$A" "c:Shutdown:$C"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'trap "" EXIT; source "$1/../common.sh"; sim_boot c' _ "$here" >"$fake/empty2.out" 2>&1 &
pz=$!
until_true "the empty-trap waiter has a ticket" tickets_are 1
kill -TERM "$pz"; reap "$pz"
[[ "$reaped" == 143 && "$(tickets)" == 0 ]] && echo "ok   and a waiter with one, stopped, still drops its ticket" \
  || fail "empty EXIT trap, stopped: status $reaped, tickets $(tickets): $(cat "$fake/empty2.out")"

# A waiter in a subshell (not \$\$) killed while its parent lives: its ticket is its own pid's, so
# it is pruned and doesn't block the queue.
devices "a:Booted:$A" "c:Shutdown:$C" "d:Shutdown:$D"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'source "$1/../common.sh"; ( sim_boot c ) & echo $! >"$2"; sleep 60' _ "$here" "$fake/sub.pid" >/dev/null 2>&1 &
parent=$!
until_true "the subshell waiter has a ticket" tickets_are 1
sub="$(cat "$fake/sub.pid")"
ls "$QUICKR_SIM_CAP_QUEUE" | grep -q "\.$sub\$" && echo "ok   the ticket names the subshell, not the parent" \
  || fail "ticket pid: $(ls "$QUICKR_SIM_CAP_QUEUE") (subshell $sub, parent $parent)"
kill -KILL "$sub"
setstate a Shutdown
IOS_SIM_CAP=1 boot d; expect "a killed subshell's ticket doesn't block while its parent lives" 0
kill "$parent" 2>/dev/null; wait "$parent" 2>/dev/null

# Holds (sim_hold / sim_release): a run shuts down what it booted, and nothing else.
shutdowns() { cat "$FAKE_DEVICES.shutdowns" 2>/dev/null | grep -c "^$1\$"; }
hold() {  # hold <udid> [script after the hold]: a run holding the device, bounded
  out="$(perl -e 'alarm shift; exec @ARGV' 60 bash -c 'source "$1/../common.sh"; sim_hold "$2"; eval "${3:-true}"' _ "$here" "$@" 2>&1)"
  status=$?
}
rm -f "$FAKE_DEVICES.shutdowns"
devices "h:Shutdown:quickR iOS-26-0 hold-1"
hold h '[[ "$(xcrun simctl list devices | grep -c "(h) (Booted)")" == 1 ]]'
expect "a hold boots the device" 0
[[ "$(state h)" == Shutdown && "$(shutdowns h)" == 1 ]] && echo "ok   and shuts it down when the run ends" \
  || fail "after the run: $(state h), $(shutdowns h) shutdowns"

devices "h:Booted:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
hold h; expect "a hold on a device someone booted (no hold on it)" 0
[[ "$(state h)" == Booted && "$(shutdowns h)" == 0 ]] && echo "ok   leaves it booted" || fail "it shut down $(shutdowns h)x"

devices "h:Shutdown:quickR iOS-26-0 hold-1"
IOS_SIM_KEEP=1 hold h; expect "IOS_SIM_KEEP=1" 0 "keeping h booted"
[[ "$(state h)" == Booted ]] && echo "ok   keeps the device it booted" || fail "kept: $(state h)"
hold h; expect "a later hold of the kept device" 0
[[ "$(state h)" == Booted ]] && echo "ok   doesn't shut it down either" || fail "later hold: $(state h)"

devices "h:Shutdown:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
# (Holders wait on a background sleep, so a signal is handled at once rather than after it.)
bash -c 'source "$1/../common.sh"; sim_hold h; touch "$2"; sleep 30 & wait $!' _ "$here" "$fake/first.up" >/dev/null 2>&1 &
first=$!
until_true "the first run holds h" test -e "$fake/first.up"
hold h; expect "a second run on the same device" 0
[[ "$(state h)" == Booted && "$(shutdowns h)" == 0 ]] && echo "ok   ends without shutting down what the first still uses" \
  || fail "second release: $(state h), $(shutdowns h) shutdowns"
kill -TERM "$first"; reap "$first"
[[ "$(state h)" == Shutdown && "$(shutdowns h)" == 1 ]] && echo "ok   TERM ends the first through its release, which shuts it down" \
  || fail "first, TERMed: $(state h), $(shutdowns h) shutdowns"

devices "h:Shutdown:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
bash -c 'source "$1/../common.sh"; sim_hold h; touch "$2"; sleep 30 & wait $!' _ "$here" "$fake/dead.up" >/dev/null 2>&1 &
dead=$!
until_true "the run that will die holds h" test -e "$fake/dead.up"
kill -KILL "$dead"; reap "$dead"
[[ "$(state h)" == Booted ]] || fail "a KILLed holder can't release: h should still be booted"
hold h; expect "a run after a holder died without releasing" 0
[[ "$(state h)" == Shutdown && "$(shutdowns h)" == 1 ]] && echo "ok   prunes the dead hold and shuts down what a hold booted" \
  || fail "after a dead holder: $(state h), $(shutdowns h) shutdowns"

# A run queued for a slot while someone boots its device by hand: it never booted it, so it
# leaves it booted.
devices "a:Booted:$A" "h:Shutdown:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'source "$1/../common.sh"; sim_hold h' _ "$here" >"$fake/queued.out" 2>&1 &
queued=$!
until_true "the hold queues" grep -q "waiting for a simulator slot" "$fake/queued.out"
setstate h Booted
setstate a Shutdown
reap "$queued"
[[ "$reaped" == 0 && "$(state h)" == Booted && "$(shutdowns h)" == 0 ]] \
  && echo "ok   a hold that found the device booted by hand at admission leaves it booted" \
  || fail "booted while queued: status $reaped, $(state h), $(shutdowns h) shutdowns; $(cat "$fake/queued.out")"

# A failed shutdown whose state check fails too (CoreSimulator down) keeps the mark as well.
devices "h:Shutdown:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
out="$(perl -e 'alarm shift; exec @ARGV' 60 bash -c 'source "$1/../common.sh"; sim_hold h; export FAKE_SHUTDOWN_FAIL=1 FAKE_LIST_FAIL=1' _ "$here" 2>&1)"
status=$?
expect "a failed shutdown with simctl unable to list" 0 "will try again"
[[ -e "$QUICKR_SIM_HOLDS/h/ours" ]] && echo "ok   keeps the mark: nothing confirmed the device is down" \
  || fail "the mark was dropped without a confirmed shutdown"
hold h; expect "the next run" 0
[[ "$(state h)" == Shutdown ]] && echo "ok   shuts it down" || fail "after the unconfirmed shutdown: $(state h)"

# TERM while queued: the run ends at once through its release (no wait on its own lock), its
# ticket and hold gone, nothing shut down.
devices "a:Booted:$A" "h:Shutdown:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
IOS_SIM_CAP=1 IOS_SIM_WAIT=1 bash -c 'source "$1/../common.sh"; sim_hold h' _ "$here" >"$fake/term.out" 2>&1 &
queued=$!
until_true "the hold queues" grep -q "waiting for a simulator slot" "$fake/term.out"
start=$SECONDS
kill -TERM "$queued"; reap "$queued"
[[ "$reaped" == 143 ]] && (( SECONDS - start < 20 )) && echo "ok   TERM while queued ends the run promptly (143)" \
  || fail "TERM while queued: status $reaped after $((SECONDS - start)) s; $(cat "$fake/term.out")"
[[ -z "$(ls "$QUICKR_SIM_HOLDS/h" 2>/dev/null | grep -v '^ours$')" && "$(tickets)" == 0 && "$(shutdowns h)" == 0 ]] \
  && echo "ok   and leaves no hold, no ticket, no shutdown" \
  || fail "after TERM: holds $(ls "$QUICKR_SIM_HOLDS/h"), tickets $(tickets), $(shutdowns h) shutdowns"

# A shutdown that fails keeps the mark, and the next run's release tries again.
devices "h:Shutdown:quickR iOS-26-0 hold-1"
rm -f "$FAKE_DEVICES.shutdowns"
FAKE_SHUTDOWN_FAIL=1 hold h; expect "a run whose shutdown fails" 0 "will try again"
[[ "$(state h)" == Booted ]] || fail "the failed shutdown left h $(state h)"
hold h; expect "the next run" 0
[[ "$(state h)" == Shutdown && "$(shutdowns h)" == 2 ]] && echo "ok   retries the shutdown and succeeds" \
  || fail "retry: $(state h), $(shutdowns h) shutdowns"

devices "h:Shutdown:quickR iOS-26-0 hold-1"
out="$(perl -e 'alarm shift; exec @ARGV' 60 bash -c 'source "$1/../common.sh"; trap "echo caller-exit \$?" EXIT; sim_hold h; exit 7' _ "$here" 2>&1)"
status=$?
expect "the caller's EXIT handler still runs after the release, with the run's status" 7 "caller-exit 7"
[[ "$(state h)" == Shutdown ]] && echo "ok   and the device is shut down" || fail "with a caller trap: $(state h)"

(( fails == 0 )) && echo "sim cap: all passed" || { echo "sim cap: $fails failed"; exit 1; }
