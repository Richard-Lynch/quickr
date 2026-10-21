# Sourced by the other ios/scripts. Paths, the Xcode guard, simulator lookup and an xcodebuild wrapper.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$IOS_DIR/.." && pwd)"
PROJECT="$IOS_DIR/quickR.xcodeproj"
SCHEME="QuickR"
BUNDLE_ID="com.bahumia.quickr"
BUILD_DIR="$IOS_DIR/build"
DERIVED="$BUILD_DIR/dd"
SPM_DIR="$BUILD_DIR/spm"
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/QuickR.app"

# The one tracked lockfile (PLAN §2), present once QuickrKit has remote dependencies. Host
# SwiftPM reads it directly; Xcode 27 also seeds from a local package's lockfile, and gen.sh
# copies it into the generated workspace as well. Both sides run with "only use versions from
# the resolved file", so a stale pin fails the build. `make ios-resolve` updates it.
RESOLVED="$IOS_DIR/QuickrKit/Package.resolved"
WORKSPACE_RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

die() { echo "ios: $*" >&2; exit 1; }
warn() { echo "ios: warning: $*" >&2; }

# Full Xcode. The CLT ship an `xcodebuild` stub that errors, so run `-version`.
require_xcodebuild() {
  xcodebuild -version >/dev/null 2>&1 || die "full Xcode not found (xcode-select -p = $(xcode-select -p 2>/dev/null || echo none)).
  Install Xcode 27.x, then: sudo xcode-select -s /Applications/Xcode-27.x.app && sudo xcodebuild -runFirstLaunch"
}

# Full Xcode and xcodegen: the guard every `make ios-*` target runs.
require_xcode() {
  require_xcodebuild
  command -v xcodegen >/dev/null || die "xcodegen not found: brew install xcodegen"
}

# Prints the UDID for a simulator given its exact name or UDID. With several matches
# (same name on different runtimes) the first one, which is the oldest runtime, wins.
sim_udid() {
  local want="$1" udid
  if [[ "$want" =~ ^[0-9A-Fa-f-]{36}$ ]]; then echo "$want"; return; fi
  udid="$(xcrun simctl list devices available | grep -F "    $want (" | head -1 \
    | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')" || true
  [[ -n "$udid" ]] || die "no available simulator named '$want' (see: xcrun simctl list devices available)"
  echo "$udid"
}

# The cap on booted quickR simulators, so parallel worktrees don't swamp the Mac. Every device
# named "quickR ..." counts: the worktree clones (sim-clone.sh names them "<source>
# <dir>-<hash6>") and the shared base devices they come from. Prints one "<udid> <name>" line
# per booted one other than $1, or "self" alone when $1 is already booted (re-booting your own
# device, or using it while booted, never counts against you).
booted_clones() {
  xcrun simctl list -j devices | python3 -c '
import json, sys
me = sys.argv[1]
out = []
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["state"] != "Booted":
            continue
        if d["udid"] == me:
            print("self")
            sys.exit()
        if d["name"].startswith("quickR "):
            out.append(d["udid"] + " " + d["name"])
print("\n".join(out))
' "$1"
}

# The UDID for a make target's simulator $1 (a name or UDID). Used as given when it was set
# explicitly, under CI, or when it is a UDID. When make only defaulted it
# (IOS_SIM_DEFAULTED=1), outside CI, it is this worktree's clone of $1 instead (created if
# missing, not booted), so a plain `make ios-test` never lands on the shared base device.
target_sim_udid() {
  if [[ "${IOS_SIM_DEFAULTED:-0}" == 1 && -z "${CI:-}" && ! "$1" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    local udid
    udid="$("$IOS_DIR/scripts/sim-clone.sh" --no-boot "$1")" || die "could not find or create this worktree's clone of '$1'"
    echo "ios: using this worktree's simulator $udid (a clone of '$1'; set IOS_SIM/IOS_SIM_MIN for another)" >&2
    echo "$udid"
  else
    sim_udid "$1"
  fi
}

# Boots simulator $1 (if it isn't already) and waits until it is ready, admitted by the cap:
# while IOS_SIM_CAP (default 2; 0 = no cap) other quickR simulators are booted it fails, naming them, or
# with IOS_SIM_WAIT=1 polls every IOS_SIM_WAIT_POLL seconds (default 15) until a slot frees.
# Admission is atomic across worktrees: one machine-wide lock is held from the check until
# the device shows as booted, and released while waiting (then the check runs again).
#
# Waiters are served in order (FIFO): one that has to wait takes a ticket, and a free slot goes
# only to the lowest live ticket, never to whoever polls first. A newcomer finding waiters
# queued joins the queue even when a slot is free. A ticket is the file
# `<number>.<pid>` in SIM_CAP_QUEUE, holding its waiter's start time; it is removed when the
# waiter is admitted or gives up, by an EXIT trap, and, for a waiter that died (its pid gone,
# or reused by another process), by the next waiter that looks. Re-booting a device that is
# already booted, and IOS_SIM_CAP=0, never queue.
SIM_CAP_LOCK="${QUICKR_SIM_CAP_LOCK:-${TMPDIR:-/tmp}/quickr-sim-cap.lockf}"
SIM_CAP_QUEUE="${QUICKR_SIM_CAP_QUEUE:-${SIM_CAP_LOCK%.lockf}.queue}"
_sim_ticket=""
# The caller's handlers for EXIT and the signals, set aside while this process waits.
_sim_saved_traps=""

# A process's start time, which tells it from a later process with the same pid.
_sim_started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

# Under the lock: removes dead waiters' tickets, then prints the live ones, lowest first.
_sim_live_tickets() {
  local file pid
  mkdir -p "$SIM_CAP_QUEUE"
  for file in "$SIM_CAP_QUEUE"/[0-9]*.[0-9]*; do
    [[ -e "$file" ]] || continue
    pid="${file##*.}"
    if [[ "$(_sim_started "$pid")" == "$(cat "$file" 2>/dev/null)" && -n "$(_sim_started "$pid")" ]]; then
      echo "$file"
    else
      rm -f "$file"
    fi
  done | sort
}

# Under the lock: this process's ticket, taken from the counter if it has none. The waiter is
# the process running this, which in a subshell isn't `$$` (bash 3.2 has no BASHPID): a child
# `sh` started as a plain command reports it as its parent.
_sim_take_ticket() {
  [[ -n "$_sim_ticket" && -e "$_sim_ticket" ]] && return 0
  local next pid
  next="$(cat "$SIM_CAP_QUEUE/next" 2>/dev/null || echo 0)"
  [[ "$next" =~ ^[0-9]+$ ]] || next=0
  echo $((next + 1)) >"$SIM_CAP_QUEUE/next"
  sh -c 'echo $PPID' >"$SIM_CAP_QUEUE/pid.$next"
  read -r pid <"$SIM_CAP_QUEUE/pid.$next"
  rm -f "$SIM_CAP_QUEUE/pid.$next"
  _sim_ticket="$SIM_CAP_QUEUE/$(printf '%012d' "$next").$pid"
  _sim_started "$pid" >"$_sim_ticket"
}

# While waiting: the ticket is dropped however the process ends. EXIT drops it, then runs the
# caller's own EXIT handler with `$?` as it was and errexit as it was; INT, TERM and HUP (fatal
# by default, and then no EXIT trap would run) end the process through EXIT, unless the caller
# traps them itself (an ignored signal, `trap '' TERM`, stays ignored). The caller's traps are
# saved as they were, present or absent, and put back when admitted.
_sim_trap_ticket() {
  local words sig handler present
  _sim_saved_traps=""
  for sig in EXIT INT TERM HUP; do
    words=()
    eval "words=($(trap -p "$sig"))"
    present=0; handler=""
    if (( ${#words[@]} > 0 )); then present=1; handler="${words[2]}"; fi
    _sim_saved_traps+="$(printf '%s %s %q' "$sig" "$present" "$handler")"$'\n'
    case "$sig" in
      EXIT)
        # The handler runs at the end of an `||` list, after a command that returns the saved
        # status: `$?` is that status inside it, and errexit (if the caller set it) still applies.
        # (An empty handler, `trap '' EXIT`, has nothing to run, and would leave empty bodies.)
        if (( present )) && [[ -n "$handler" ]]; then
          trap "_sim_rc=\$?; _sim_drop_ticket; if (( _sim_rc == 0 )); then $handler
else _sim_status \$_sim_rc || { $handler
}; fi" EXIT
        else
          trap '_sim_drop_ticket' EXIT
        fi
        ;;
      INT) (( present )) || trap 'exit 130' INT ;;
      TERM) (( present )) || trap 'exit 143' TERM ;;
      HUP) (( present )) || trap 'exit 129' HUP ;;
    esac
  done
}

_sim_status() { return "$1"; }

# Admitted: the caller's traps back exactly as they were (absent, ignored or a handler).
_sim_untrap_ticket() {
  local sig present handler
  while read -r sig present handler; do
    [[ -n "$sig" ]] || continue
    eval "handler=$handler"
    if (( present )); then trap -- "$handler" "$sig"; else trap - "$sig"; fi
  done <<<"$_sim_saved_traps"
  _sim_saved_traps=""
}

_sim_drop_ticket() {
  [[ -n "$_sim_ticket" ]] && rm -f "$_sim_ticket"
  _sim_ticket=""
}

sim_boot() {
  local udid="$1" cap="${IOS_SIM_CAP:-2}" booted count announced=0 lock_status tickets ahead position
  local last_position=0 trapped=0
  # CI runs one simulator per runner: no cap to enforce, and xcodebuild boots the device itself
  # (an unbounded `simctl bootstatus -b` there stalled a run until the step's time limit).
  [[ -n "${CI:-}" ]] && return 0
  while :; do
    exec 8>>"$SIM_CAP_LOCK"
    lock_status=0
    /usr/bin/lockf -t "${IOS_SIM_LOCK_WAIT:-900}" 8 >/dev/null 2>&1 || lock_status=$?
    (( lock_status == 0 )) || { exec 8>&-; _sim_drop_ticket; die "could not take the simulator lock $SIM_CAP_LOCK (lockf $lock_status)"; }
    booted="$(booted_clones "$udid")"
    count="$(grep -c . <<<"$booted" || true)"
    tickets="$(_sim_live_tickets)"
    # Live tickets ahead of this process's own (all of them if it has none yet).
    if [[ -n "$_sim_ticket" ]]; then
      ahead="$(grep -c . <<<"$(awk -v me="$_sim_ticket" '$0 < me' <<<"$tickets")" || true)"
    else
      ahead="$(grep -c . <<<"$tickets" || true)"
    fi
    if [[ "$booted" == self || "$cap" == 0 ]] || { (( count < cap )) && (( ahead == 0 )); }; then
      _sim_drop_ticket
      # The boot runs without fd 8, so nothing it starts can hold the lock.
      # Bounded: a boot that never completes fails here instead of stalling the caller.
      if ! perl -e 'alarm shift; exec @ARGV' "${IOS_SIM_BOOT_TIMEOUT:-300}" \
        xcrun simctl bootstatus "$udid" -b >/dev/null 8>&-; then
        exec 8>&-
        die "simulator $udid did not finish booting within ${IOS_SIM_BOOT_TIMEOUT:-300} s"
      fi
      exec 8>&-
      (( trapped )) && _sim_untrap_ticket
      return 0
    fi
    if [[ "${IOS_SIM_WAIT:-0}" != 1 ]]; then
      exec 8>&-
      if (( count < cap )); then
        die "$ahead waiting ahead for a simulator slot (IOS_SIM_CAP=$cap); wait your turn (--wait / IOS_SIM_WAIT=1)"
      fi
      die "$count quickR simulators are booted (IOS_SIM_CAP=$cap); shut one down or wait (--wait / IOS_SIM_WAIT=1):
$(sed 's/^/  /' <<<"$booted")"
    fi
    if [[ -z "$_sim_ticket" ]]; then
      # Traps first: a signal between taking the ticket and trapping would leave it behind.
      _sim_trap_ticket
      trapped=1
      _sim_take_ticket
    fi
    exec 8>&-
    position=$(( ahead + 1 ))
    if (( !announced )); then
      echo "ios: waiting for a simulator slot ($count booted, IOS_SIM_CAP=$cap; place $position in the queue):" >&2
      sed 's/^/  /' <<<"$booted" >&2
      announced=1
      last_position=$position
    elif (( position != last_position )); then
      echo "ios: still waiting for a simulator slot: place $position in the queue" >&2
      last_position=$position
    fi
    sleep "${IOS_SIM_WAIT_POLL:-15}"
  done
}

# Parallel compile jobs per build. Several worktrees build at once on one Mac, and each
# build defaults to one job per core, which oversubscribes it badly. IOS_JOBS=0 = no cap.
IOS_JOBS="${IOS_JOBS:-4}"

# Runs a command under watchdog.sh: killed, with its whole process group, after
# IOS_WATCHDOG_SILENCE_MIN minutes without any output (default 20), or 60 s after xcodebuild's
# final "** … SUCCEEDED/FAILED **" line if it hasn't exited by then. IOS_WATCHDOG=0 turns it
# off. Output is merged onto stdout.
watchdog() {
  "$IOS_DIR/scripts/watchdog.sh" "$@"
}

# xcodebuild against the generated project, with shared DerivedData and SPM checkout dirs.
# XCODEBUILD runs instead of xcodebuild when set (testflight.sh filters the output first).
# Packages resolve only to the tracked pins when there are any. Runs under the watchdog;
# output goes through xcbeautify when it is installed. xcbeautify block-buffers a pipe (a CI
# log saw nothing until it exited), so it writes to a terminal of its own (linebuffered.py)
# and its lines stream.
xcb() {
  local args=(-project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DERIVED"
    -clonedSourcePackagesDirPath "$SPM_DIR")
  [[ -f "$RESOLVED" ]] && args+=(-onlyUsePackageVersionsFromResolvedFile)
  [[ "$IOS_JOBS" != 0 ]] && args+=(-jobs "$IOS_JOBS")
  args+=("$@")
  # The first build fetches the packages, which can be quiet for a long time: at least 40 min
  # then, even when IOS_WATCHDOG_SILENCE_MIN is lower (CI sets 5 for the test step).
  local silence="${IOS_WATCHDOG_SILENCE_MIN:-20}"
  [[ -d "$SPM_DIR/checkouts" ]] || (( silence >= 40 )) || silence=40
  if command -v xcbeautify >/dev/null; then
    IOS_WATCHDOG_SILENCE_MIN="$silence" watchdog "${XCODEBUILD:-xcodebuild}" "${args[@]}" | "$IOS_DIR/scripts/linebuffered.py" xcbeautify --quiet
  else
    IOS_WATCHDOG_SILENCE_MIN="$silence" watchdog "${XCODEBUILD:-xcodebuild}" "${args[@]}"
  fi
}

# `swift test` for QuickrKit on the host, held to the tracked pins when there are any.
swift_test() {
  local flags=()
  [[ -f "$RESOLVED" ]] && flags+=(--only-use-versions-from-resolved-file)
  [[ "$IOS_JOBS" != 0 ]] && flags+=(--jobs "$IOS_JOBS")
  watchdog swift test --package-path "$IOS_DIR/QuickrKit" ${flags[@]+"${flags[@]}"} "$@"
}
