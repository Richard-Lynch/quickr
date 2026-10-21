#!/usr/bin/env bash
# Tests for device-run.sh against a fake `xcrun devicectl` and `xcodebuild`, in a throwaway copy
# of ios/scripts: picking the device (by name, UDID or CoreDevice id, or the only paired iPhone),
# the team from Local.xcconfig, and the build, install and launch it hands on. No Xcode needed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickr-devrun.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
ios="$tmp/ios"
mkdir -p "$ios/quickR.xcodeproj" "$tmp/bin"
cp -R "$here/.." "$ios/scripts"

# Devices as devicectl lists them: a paired iPhone, plus an unpaired iPhone and a paired watch
# that must be skipped.
device() {  # name udid identifier platform reality pairing
  printf '{"identifier":"%s","deviceProperties":{"name":"%s"},"hardwareProperties":{"udid":"%s","platform":"%s","reality":"%s"},"connectionProperties":{"pairingState":"%s"}}' \
    "$3" "$1" "$2" "$4" "$5" "$6"
}
phone=$(device "Test iPhone" 00008140-AAAA 11111111-AAAA iOS physical paired)
other=$(device "Other iPhone" 00008140-BBBB 22222222-BBBB iOS physical unpaired)
watch=$(device "Test Watch" 00008301-CCCC 33333333-CCCC watchOS physical paired)
printf '{"result":{"devices":[%s,%s,%s]}}' "$phone" "$other" "$watch" >"$tmp/one.json"
second=$(device "Second iPhone" 00008140-DDDD 44444444-DDDD iOS physical paired)
printf '{"result":{"devices":[%s,%s]}}' "$phone" "$second" >"$tmp/two.json"

cat >"$tmp/bin/xcrun" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
if [[ "$1 $2 $3" == "devicectl list devices" ]]; then
  while [[ $# -gt 0 && "$1" != --json-output ]]; do shift; done
  cp "$FAKE_DEVICES" "$2"
fi
SH
cat >"$tmp/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -version ]] && { echo "Xcode 27.0"; exit 0; }
printf 'xcodebuild %s\n' "$*" >>"$FAKE_LOG"
for arg; do [[ "$prev" == -derivedDataPath ]] && mkdir -p "$arg/Build/Products/Debug-iphoneos/QuickR.app"; prev="$arg"; done
SH
chmod +x "$tmp/bin/xcrun" "$tmp/bin/xcodebuild"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }
run() {  # run [VAR=value...] [args...]: device-run.sh with a clean environment; sets $status
  : >"$tmp/log"
  rm -rf "$ios/build"
  env -i HOME="$tmp" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" IOS_WATCHDOG=0 FAKE_LOG="$tmp/log" \
    FAKE_DEVICES="${devices:-$tmp/one.json}" "$@" >"$tmp/out" 2>&1
  status=$?
}
dr="$ios/scripts/device-run.sh"

run "$dr"
(( status != 0 )) && grep -q "no DEVELOPMENT_TEAM" "$tmp/out" && ok "no team: refused" || fail "no team: $(cat "$tmp/out")"

printf 'DEVELOPMENT_TEAM = TEAM123456 // mine\nQUICKR_DEVICE =\n' >"$ios/Local.xcconfig"
run "$dr"
if (( status == 0 )) && grep -q "xcodebuild .*-destination id=00008140-AAAA .*-allowProvisioningUpdates DEVELOPMENT_TEAM=TEAM123456 build" "$tmp/log" \
  && grep -q "devicectl device install app --device 00008140-AAAA .*Debug-iphoneos/QuickR.app" "$tmp/log" \
  && grep -q "devicectl device process launch --device 00008140-AAAA --terminate-existing com.bahumia.quickr" "$tmp/log"; then
  ok "the only paired iPhone: built, installed and launched; the team from Local.xcconfig"
else
  fail "only paired iPhone (status $status): $(cat "$tmp/out") // $(cat "$tmp/log")"
fi

for pick in "Test iPhone" 00008140-AAAA 11111111-AAAA; do
  devices="$tmp/two.json" run "$dr" "$pick"
  (( status == 0 )) && grep -q "install app --device 00008140-AAAA" "$tmp/log" && ok "picked by '$pick'" \
    || fail "pick '$pick' (status $status): $(cat "$tmp/out")"
done
devices="$tmp/two.json" run QUICKR_DEVICE="Second iPhone" "$dr"
grep -q "install app --device 00008140-DDDD" "$tmp/log" && ok "QUICKR_DEVICE from the environment" || fail "QUICKR_DEVICE: $(cat "$tmp/out")"

devices="$tmp/two.json" run "$dr"
(( status != 0 )) && grep -q "several paired iPhones (paired: Second iPhone, Test iPhone)" "$tmp/out" && ! grep -q "xcodebuild" "$tmp/log" \
  && ok "two paired iPhones and none chosen: refused, by name only" || fail "ambiguous (status $status): $(cat "$tmp/out")"
grep -qE "0000|1111|4444" "$tmp/out" && fail "an identifier was printed: $(cat "$tmp/out")" || ok "no identifier printed"
run "$dr" "Other iPhone"
(( status != 0 )) && grep -q "no paired iPhone matches 'Other iPhone'" "$tmp/out" && ok "an unpaired iPhone isn't used" \
  || fail "unpaired (status $status): $(cat "$tmp/out")"
run "$dr" "Test Watch"
(( status != 0 )) && ok "a watch isn't used" || fail "watch picked: $(cat "$tmp/log")"

run IOS_LAUNCH_ARGS="-QuickrDemoStore" "$dr" "" "quickr://t/water/record"
grep -q "process launch --device 00008140-AAAA --terminate-existing --payload-url quickr://t/water/record com.bahumia.quickr -QuickrDemoStore" "$tmp/log" \
  && ok "a URL and launch arguments are passed" || fail "url/args: $(cat "$tmp/log")"

if (( failures )); then
  echo "device-run-test: $failures failed"
  exit 1
fi
echo "device-run-test: all passed"
