#!/usr/bin/env bash
# make ios-device-run: a signed Debug build for the paired iPhone, installed and launched with
# devicectl, optionally opening a URL. Usage: device-run.sh [device] [url]
# The device: $1, else QUICKR_DEVICE (the environment, else ios/Local.xcconfig): its name, UDID
# or CoreDevice identifier, as `xcrun devicectl list devices` shows them. With none set, the one
# paired iPhone, if there is exactly one. Signing is automatic, with DEVELOPMENT_TEAM from the
# environment or ios/Local.xcconfig and the account signed in to Xcode (docs/ios/demo/DEVICE-DAY.md).
# IOS_LAUNCH_ARGS: arguments for the app, as for sim-run.sh.
# Device identifiers (UDID, CoreDevice id, ECID, serial number) and the Team ID never reach the
# output or the watchdog's files: every tool runs as this script called back
# (QUICKR_DR_SCRUB=1), which filters them out first.
source "$(dirname "$0")/common.sh"

# A value from ios/Local.xcconfig (`NAME = value`, a trailing // comment dropped).
xcconfig_value() {
  [[ -f "$IOS_DIR/Local.xcconfig" ]] || return 0
  sed -nE "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*||p" "$IOS_DIR/Local.xcconfig" | tail -1 \
    | sed -E 's|[[:space:]]*//.*$||; s|[[:space:]]+$||'
}

# Replaces each of QUICKR_DR_SECRETS (newline-separated) with <device>, and the team with ****.
scrub() {
  local args=() secret
  while IFS= read -r secret; do
    [[ -n "$secret" ]] && args+=(-e "s/$secret/<device>/g")
  done <<<"${QUICKR_DR_SECRETS:-}"
  [[ -n "${QUICKR_DR_TEAM:-}" ]] && args+=(-e "s/$QUICKR_DR_TEAM/****${QUICKR_DR_TEAM: -2}/g")
  if (( ${#args[@]} )); then sed -l "${args[@]}"; else cat; fi
}
# Called back: `--run <command...>` runs that command, anything else is xcodebuild's arguments
# (as xcb passes them through XCODEBUILD).
if [[ "${QUICKR_DR_SCRUB:-}" == 1 ]]; then
  if [[ "${1:-}" == --run ]]; then
    shift
    "$@" 2>&1 | scrub
  else
    xcodebuild "$@" 2>&1 | scrub
  fi
  exit "${PIPESTATUS[0]}"
fi

require_xcodebuild
[[ -d "$PROJECT" ]] || die "no $PROJECT: run make ios-gen first"
team="${DEVELOPMENT_TEAM:-$(xcconfig_value DEVELOPMENT_TEAM)}"
[[ -n "$team" ]] || die "no DEVELOPMENT_TEAM: set it in ios/Local.xcconfig (copy ios/Local.xcconfig.example);
  docs/ios/demo/DEVICE-DAY.md lists the steps before a device build"
want="${1:-${QUICKR_DEVICE:-$(xcconfig_value QUICKR_DEVICE)}}"
url="${2:-}"

# The device from devicectl's JSON (paired, physical iOS devices only): its name, then its UDID
# (what xcodebuild's destination takes; devicectl takes it too), then every identifier to
# filter out, one per line. On failure it prints device names only.
json="$(mktemp "${TMPDIR:-/tmp}/quickr-devices.XXXXXX")"
trap 'rm -f "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 \
  || die "xcrun devicectl list devices failed: is Xcode's device support installed?"
picked="$(python3 - "$json" "$want" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
devices = []
for d in json.load(open(path)).get("result", {}).get("devices", []):
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical" or conn.get("pairingState") != "paired":
        continue
    ids = [hw.get("udid", ""), d.get("identifier", ""), str(hw.get("ecid", "")), hw.get("serialNumber", "")]
    devices.append((props.get("name", "?"), [i for i in ids if i]))
if want:
    match = [d for d in devices if want == d[0] or want in d[1]]
else:
    match = devices
if len(match) == 1 and match[0][1]:
    print(match[0][0])
    print("\n".join(match[0][1]))
    sys.exit(0)
names = ", ".join(sorted(d[0] for d in devices)) or "none"
if want:
    sys.exit(f"no paired iPhone matches the device given (paired: {names})")
sys.exit(f"{'no paired iPhone' if not devices else 'several paired iPhones'} (paired: {names}); "
         "set QUICKR_DEVICE in ios/Local.xcconfig or pass one: make ios-device-run IOS_DEVICE=<name>")
PY
)" || die "can't pick the device"
name="$(sed -n 1p <<<"$picked")"
udid="$(sed -n 2p <<<"$picked")"
QUICKR_DR_SECRETS="$(sed 1d <<<"$picked")"
export QUICKR_DR_SCRUB=1 QUICKR_DR_SECRETS QUICKR_DR_TEAM="$team"
XCODEBUILD="$IOS_DIR/scripts/device-run.sh"
run() { "$IOS_DIR/scripts/device-run.sh" --run "$@"; }  # a tool, its output filtered

echo "ios: signed Debug build for $name"
# -allowProvisioningDeviceRegistration registers a phone the team doesn't know yet.
xcb -configuration Debug -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$team" build
app="$DERIVED/Build/Products/Debug-iphoneos/QuickR.app"
[[ -d "$app" ]] || die "the build produced no $app"
run xcrun devicectl device install app --device "$udid" "$app" \
  || die "install failed: is the phone unlocked, trusting this Mac, with Developer Mode on?"
launch=(run xcrun devicectl device process launch --device "$udid" --terminate-existing)
[[ -n "$url" ]] && launch+=(--payload-url "$url")
# shellcheck disable=SC2086 # split on purpose: several arguments
"${launch[@]}" "$BUNDLE_ID" ${IOS_LAUNCH_ARGS:-} || die "launch failed: unlock the phone and run it again"
