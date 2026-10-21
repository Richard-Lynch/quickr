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

# Filters a stream: every identifier in QUICKR_DR_SECRETS (newline-separated, those of every
# device devicectl listed) becomes <device>, matched literally; so does anything shaped like a
# UDID (00008xxx-xxxxxxxxxxxxxxxx, or 40 hex digits) or labelled as an ECID or serial number,
# in case a tool prints one devicectl didn't list. The Team ID keeps its last two characters.
scrub() {
  perl -pe '
    BEGIN {
      $| = 1;
      @ids = sort { length($b) <=> length($a) } grep { length } split /\n/, ($ENV{QUICKR_DR_SECRETS} // "");
      $team = $ENV{QUICKR_DR_TEAM} // "";
    }
    for my $id (@ids) { s/\Q$id\E/<device>/g }
    s/\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b/<device>/g;
    s/\b[0-9a-fA-F]{40}\b/<device>/g;
    s/\b(ecid|ECID|serial ?number|serialNumber|Serial ?Number)(["\x27]?\s*[:=]\s*["\x27]?|\s+)(0x)?[0-9A-Za-z]+/$1$2<device>/g;
    if (length $team) { my $r = "****" . substr($team, -2); s/\Q$team\E/$r/g }
  '
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
# (what xcodebuild's destination takes; devicectl takes it too), then the identifiers of every
# device listed, paired or not, to filter out, one per line. On failure it prints device names
# only. The JSON holds them raw, so it is private to this run and removed as soon as it's read.
json="$(mktemp "${TMPDIR:-/tmp}/quickr-devices.XXXXXX")"
trap 'rm -f "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 \
  || die "xcrun devicectl list devices failed: is Xcode's device support installed?"
picked="$(python3 - "$json" "$want" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
devices, every_id = [], []
for d in json.load(open(path)).get("result", {}).get("devices", []):
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    ids = [str(i) for i in (hw.get("udid"), d.get("identifier"), hw.get("ecid"), hw.get("serialNumber")) if i]
    every_id += ids
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical" or conn.get("pairingState") != "paired":
        continue
    devices.append((props.get("name", "?"), ids, hw.get("udid", "")))
if want:
    match = [d for d in devices if want == d[0] or want in d[1]]
else:
    match = devices
if len(match) == 1 and match[0][2]:
    print(match[0][0])
    print(match[0][2])
    print("\n".join(every_id))
    sys.exit(0)
names = ", ".join(sorted(d[0] for d in devices)) or "none"
if want:
    sys.exit(f"no paired iPhone matches the device given (paired: {names})")
sys.exit(f"{'no paired iPhone' if not devices else 'several paired iPhones'} (paired: {names}); "
         "set QUICKR_DEVICE in ios/Local.xcconfig or pass one: make ios-device-run IOS_DEVICE=<name>")
PY
)" || die "can't pick the device"
rm -f "$json"
name="$(sed -n 1p <<<"$picked")"
udid="$(sed -n 2p <<<"$picked")"
QUICKR_DR_SECRETS="$(sed 1d <<<"$picked")"
export QUICKR_DR_SCRUB=1 QUICKR_DR_SECRETS QUICKR_DR_TEAM="$team"
XCODEBUILD="$IOS_DIR/scripts/device-run.sh"
run() { "$IOS_DIR/scripts/device-run.sh" --run "$@"; }  # a tool, its output filtered

echo "ios: signed Debug build for $name" | scrub
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
