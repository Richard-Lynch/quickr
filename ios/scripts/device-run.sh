#!/usr/bin/env bash
# make ios-device-run: a signed Debug build for the paired iPhone, installed and launched with
# devicectl, optionally opening a URL. Usage: device-run.sh [device] [url]
# The device: $1, else QUICKR_DEVICE (the environment, else ios/Local.xcconfig): its name, UDID
# or CoreDevice identifier, as `xcrun devicectl list devices` shows them. With none set, the one
# paired iPhone, if there is exactly one. Signing is automatic, with DEVELOPMENT_TEAM from the
# environment or ios/Local.xcconfig and the account signed in to Xcode (docs/ios/demo/DEVICE-DAY.md).
# IOS_LAUNCH_ARGS: arguments for the app, as for sim-run.sh.
source "$(dirname "$0")/common.sh"
require_xcodebuild
[[ -d "$PROJECT" ]] || die "no $PROJECT: run make ios-gen first"

# A value from ios/Local.xcconfig (`NAME = value`, a trailing // comment dropped).
xcconfig_value() {
  [[ -f "$IOS_DIR/Local.xcconfig" ]] || return 0
  sed -nE "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*||p" "$IOS_DIR/Local.xcconfig" | tail -1 \
    | sed -E 's|[[:space:]]*//.*$||; s|[[:space:]]+$||'
}

team="${DEVELOPMENT_TEAM:-$(xcconfig_value DEVELOPMENT_TEAM)}"
[[ -n "$team" ]] || die "no DEVELOPMENT_TEAM: set it in ios/Local.xcconfig (copy ios/Local.xcconfig.example);
  docs/ios/demo/DEVICE-DAY.md lists the steps before a device build"
want="${1:-${QUICKR_DEVICE:-$(xcconfig_value QUICKR_DEVICE)}}"
url="${2:-}"

# The device's UDID (what xcodebuild's destination takes; devicectl takes it too), from
# devicectl's JSON: paired, physical iOS devices only. Prints only device names on failure.
json="$(mktemp "${TMPDIR:-/tmp}/quickr-devices.XXXXXX")"
trap 'rm -f "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 \
  || die "xcrun devicectl list devices failed: is Xcode's device support installed?"
udid="$(python3 - "$json" "$want" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
devices = []
for d in json.load(open(path)).get("result", {}).get("devices", []):
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical" or conn.get("pairingState") != "paired":
        continue
    devices.append((props.get("name", "?"), hw.get("udid", ""), d.get("identifier", "")))
if want:
    match = [d for d in devices if want in d]
else:
    match = devices
if len(match) == 1 and match[0][1]:
    print(match[0][1])
    sys.exit(0)
names = ", ".join(sorted(d[0] for d in devices)) or "none"
if want:
    sys.exit(f"no paired iPhone matches '{want}' (paired: {names})")
sys.exit(f"{'no paired iPhone' if not devices else 'several paired iPhones'} (paired: {names}); "
         "set QUICKR_DEVICE in ios/Local.xcconfig or pass one: make ios-device-run IOS_DEVICE=<name>")
PY
)" || die "can't pick the device"

echo "ios: signed Debug build for the device (team from Local.xcconfig or the environment)"
xcb -configuration Debug -destination "id=$udid" -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" build
app="$DERIVED/Build/Products/Debug-iphoneos/QuickR.app"
[[ -d "$app" ]] || die "the build produced no $app"
xcrun devicectl device install app --device "$udid" "$app" \
  || die "install failed: is the phone unlocked, trusting this Mac, with Developer Mode on?"
launch=(xcrun devicectl device process launch --device "$udid" --terminate-existing)
[[ -n "$url" ]] && launch+=(--payload-url "$url")
# shellcheck disable=SC2086 # split on purpose: several arguments
"${launch[@]}" "$BUNDLE_ID" ${IOS_LAUNCH_ARGS:-} || die "launch failed: unlock the phone and run it again"
