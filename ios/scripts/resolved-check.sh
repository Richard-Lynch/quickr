#!/usr/bin/env bash
# Fail when Xcode's workspace lockfile no longer has the tracked pins (identity, version,
# revision), for example because a build re-resolved packages. Run after an Xcode build.
source "$(dirname "$0")/common.sh"
if [[ ! -f "$RESOLVED" ]]; then
  [[ -f "$WORKSPACE_RESOLVED" ]] && die "Xcode resolved remote packages but ios/QuickrKit/Package.resolved \
is missing. Run: make ios-resolve"
  echo "ios: no remote package dependencies"
  exit 0
fi
[[ -f "$WORKSPACE_RESOLVED" ]] || die "no workspace lockfile; run make ios-gen first"
python3 - "$RESOLVED" "$WORKSPACE_RESOLVED" <<'PY' || die "Xcode's pins differ from ios/QuickrKit/Package.resolved. Run: make ios-resolve"
import json, sys

def pins(path):
    with open(path) as f:
        return {
            p["identity"]: (p["state"].get("version"), p["state"].get("revision"))
            for p in json.load(f).get("pins", [])
        }

tracked, xcode = pins(sys.argv[1]), pins(sys.argv[2])
for identity in sorted(tracked.keys() | xcode.keys()):
    if tracked.get(identity) != xcode.get(identity):
        print(f"ios: {identity}: tracked {tracked.get(identity)} != Xcode {xcode.get(identity)}", file=sys.stderr)
sys.exit(tracked != xcode)
PY
echo "ios: package pins match ios/QuickrKit/Package.resolved"
