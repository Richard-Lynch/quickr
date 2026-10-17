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

die() { echo "ios: $*" >&2; exit 1; }
warn() { echo "ios: warning: $*" >&2; }

# Full Xcode and xcodegen. The CLT ship an `xcodebuild` stub that errors, so run `-version`.
require_xcode() {
  xcodebuild -version >/dev/null 2>&1 || die "full Xcode not found (xcode-select -p = $(xcode-select -p 2>/dev/null || echo none)).
  Install Xcode 27.x, then: sudo xcode-select -s /Applications/Xcode-27.x.app && sudo xcodebuild -runFirstLaunch"
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

# xcodebuild against the generated project, with shared DerivedData and SPM checkout dirs.
# Output goes through xcbeautify when it is installed.
xcb() {
  local args=(-project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DERIVED"
    -clonedSourcePackagesDirPath "$SPM_DIR" "$@")
  if command -v xcbeautify >/dev/null; then
    xcodebuild "${args[@]}" 2>&1 | xcbeautify --quiet
  else
    xcodebuild "${args[@]}"
  fi
}
