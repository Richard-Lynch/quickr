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

sim_boot() {
  xcrun simctl bootstatus "$1" -b >/dev/null
}

# Parallel compile jobs per build. Several worktrees build at once on one Mac, and each
# build defaults to one job per core, which oversubscribes it badly. IOS_JOBS=0 = no cap.
IOS_JOBS="${IOS_JOBS:-4}"

# xcodebuild against the generated project, with shared DerivedData and SPM checkout dirs.
# Packages resolve only to the tracked pins when there are any. Output goes through
# xcbeautify when it is installed.
xcb() {
  local args=(-project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DERIVED"
    -clonedSourcePackagesDirPath "$SPM_DIR")
  [[ -f "$RESOLVED" ]] && args+=(-onlyUsePackageVersionsFromResolvedFile)
  [[ "$IOS_JOBS" != 0 ]] && args+=(-jobs "$IOS_JOBS")
  args+=("$@")
  if command -v xcbeautify >/dev/null; then
    xcodebuild "${args[@]}" 2>&1 | xcbeautify --quiet
  else
    xcodebuild "${args[@]}"
  fi
}

# `swift test` for QuickrKit on the host, held to the tracked pins when there are any.
swift_test() {
  local flags=()
  [[ -f "$RESOLVED" ]] && flags+=(--only-use-versions-from-resolved-file)
  [[ "$IOS_JOBS" != 0 ]] && flags+=(--jobs "$IOS_JOBS")
  swift test --package-path "$IOS_DIR/QuickrKit" ${flags[@]+"${flags[@]}"} "$@"
}
