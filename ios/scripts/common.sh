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

# The cap on booted worktree clones (sim-clone.sh names them "<source> <dir>-<hash6>"), so
# parallel worktrees don't swamp the Mac. Prints one "<udid> <name>" line per booted clone
# other than $1, or "self" alone when $1 is already booted (re-booting your own clone, or
# using it while booted, never counts against you).
booted_clones() {
  xcrun simctl list -j devices | python3 -c '
import json, re, sys
me = sys.argv[1]
clone = re.compile(r"^quickR .+ \S+-[0-9a-f]{6}$")
out = []
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["state"] != "Booted":
            continue
        if d["udid"] == me:
            print("self")
            sys.exit()
        if clone.match(d["name"]):
            out.append(d["udid"] + " " + d["name"])
print("\n".join(out))
' "$1"
}

# Boots simulator $1 (if it isn't already) and waits until it is ready, admitted by the cap:
# while IOS_SIM_CAP (default 2; 0 = no cap) other clones are booted it fails, naming them, or
# with IOS_SIM_WAIT=1 polls every IOS_SIM_WAIT_POLL seconds (default 15) until a slot frees.
# Admission is atomic across worktrees: one machine-wide lock is held from the check until
# the device shows as booted, and released while waiting (then the check runs again).
SIM_CAP_LOCK="${QUICKR_SIM_CAP_LOCK:-${TMPDIR:-/tmp}/quickr-sim-cap.lockf}"
sim_boot() {
  local udid="$1" cap="${IOS_SIM_CAP:-2}" booted count announced=0 lock_status
  # CI runs one simulator per runner: no cap to enforce, and xcodebuild boots the device itself
  # (an unbounded `simctl bootstatus -b` there stalled a run until the step's time limit).
  [[ -n "${CI:-}" ]] && return 0
  while :; do
    exec 8>>"$SIM_CAP_LOCK"
    lock_status=0
    /usr/bin/lockf -t "${IOS_SIM_LOCK_WAIT:-900}" 8 >/dev/null 2>&1 || lock_status=$?
    (( lock_status == 0 )) || { exec 8>&-; die "could not take the simulator lock $SIM_CAP_LOCK (lockf $lock_status)"; }
    booted="$(booted_clones "$udid")"
    count="$(grep -c . <<<"$booted" || true)"
    if [[ "$booted" == self || "$cap" == 0 ]] || (( count < cap )); then
      # The boot runs without fd 8, so nothing it starts can hold the lock.
      # Bounded: a boot that never completes fails here instead of stalling the caller.
      if ! perl -e 'alarm shift; exec @ARGV' "${IOS_SIM_BOOT_TIMEOUT:-300}" \
        xcrun simctl bootstatus "$udid" -b >/dev/null 8>&-; then
        exec 8>&-
        die "simulator $udid did not finish booting within ${IOS_SIM_BOOT_TIMEOUT:-300} s"
      fi
      exec 8>&-
      return 0
    fi
    exec 8>&-
    if [[ "${IOS_SIM_WAIT:-0}" != 1 ]]; then
      die "$count simulator clones are booted (IOS_SIM_CAP=$cap); shut one down or wait (--wait / IOS_SIM_WAIT=1):
$(sed 's/^/  /' <<<"$booted")"
    fi
    if (( !announced )); then
      echo "ios: waiting for a simulator slot ($count booted, IOS_SIM_CAP=$cap):" >&2
      sed 's/^/  /' <<<"$booted" >&2
      announced=1
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
  # The first build fetches the packages, which can be quiet for a long time.
  local silence="${IOS_WATCHDOG_SILENCE_MIN:-20}"
  [[ -d "$SPM_DIR/checkouts" ]] || silence="${IOS_WATCHDOG_SILENCE_MIN:-40}"
  if command -v xcbeautify >/dev/null; then
    IOS_WATCHDOG_SILENCE_MIN="$silence" watchdog xcodebuild "${args[@]}" | "$IOS_DIR/scripts/linebuffered.py" xcbeautify --quiet
  else
    IOS_WATCHDOG_SILENCE_MIN="$silence" watchdog xcodebuild "${args[@]}"
  fi
}

# `swift test` for QuickrKit on the host, held to the tracked pins when there are any.
swift_test() {
  local flags=()
  [[ -f "$RESOLVED" ]] && flags+=(--only-use-versions-from-resolved-file)
  [[ "$IOS_JOBS" != 0 ]] && flags+=(--jobs "$IOS_JOBS")
  watchdog swift test --package-path "$IOS_DIR/QuickrKit" ${flags[@]+"${flags[@]}"} "$@"
}
