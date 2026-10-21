#!/usr/bin/env bash
# Tests for device-run.sh against a fake `xcrun devicectl` and `xcodebuild`, in a throwaway copy
# of ios/scripts: picking the device (by name, UDID or CoreDevice id, or the only paired iPhone),
# the team from Local.xcconfig, and the build, install and launch it hands on. No Xcode needed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickr-devrun.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
ios="$tmp/ios"
mkdir -p "$ios/quickR.xcodeproj" "$tmp/bin"
cp -R "$here/.." "$ios/scripts"

# Devices as devicectl lists them: a paired iPhone, plus an unpaired iPhone and a paired watch
# that must be skipped.
device() {  # name udid identifier ecid platform reality pairing (the serial is SER + the UDID's tail)
  printf '{"identifier":"%s","deviceProperties":{"name":"%s"},"hardwareProperties":{"udid":"%s","ecid":%s,"serialNumber":"SER%s","platform":"%s","reality":"%s"},"connectionProperties":{"pairingState":"%s"}}' \
    "$3" "$1" "$2" "$4" "${2: -4}" "$5" "$6" "$7"
}
phone=$(device "Test iPhone" 00008140-000000000000AAAA 11111111-AAAA 7711 iOS physical paired)
other=$(device "Other iPhone" 00008140-000000000000BBBB 22222222-BBBB 7722 iOS physical unpaired)
watch=$(device "Test Watch" 00008301-000000000000CCCC 33333333-CCCC 7733 watchOS physical paired)
printf '{"result":{"devices":[%s,%s,%s]}}' "$phone" "$other" "$watch" >"$tmp/one.json"
second=$(device "Second iPhone" 00008140-000000000000DDDD 44444444-DDDD 7744 iOS physical paired)
printf '{"result":{"devices":[%s,%s]}}' "$phone" "$second" >"$tmp/two.json"

# The fakes print what the real tools could: their arguments, and devicectl the device's ECID
# and serial number. Then they look for an identifier in the watchdog's files (FAKE_LEAKS).
cat >"$tmp/bin/xcrun" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
if [[ "$1 $2 $3" == "devicectl list devices" ]]; then
  while [[ $# -gt 0 && "$1" != --json-output ]]; do shift; done
  cp "$FAKE_DEVICES" "$2"
  exit 0
fi
echo "devicectl $* (ecid 7711, serial SERAAAA, identifier 11111111-AAAA)"
echo "ECID: 0x1234ABCD, Serial Number: XYZ999, udid 00008150-0011223344556677"  # none listed
SH
cat >"$tmp/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -version ]] && { echo "Xcode 27.0"; exit 0; }
printf 'xcodebuild %s\n' "$*" >>"$FAKE_LOG"
echo "xcodebuild $*"
echo "Available destinations: { platform:iOS, id:00008140-000000000000BBBB, name:Other iPhone } { platform:watchOS, id:00008301-000000000000CCCC, name:Test Watch }"
ls "$TMPDIR"/quickr-devices.* >>"$FAKE_LEAKS" 2>/dev/null  # devicectl's raw JSON is gone by now
sleep 0.3
grep -rhE "AAAA|7711|TEAM123456|BBBB|7733|CCCC|1234ABCD|XYZ999|0011223344556677" "$TMPDIR"/quickr-watchdog.* >>"$FAKE_LEAKS" 2>/dev/null
for arg; do [[ "$prev" == -derivedDataPath ]] && mkdir -p "$arg/Build/Products/Debug-iphoneos/QuickR.app"; prev="$arg"; done
SH
chmod +x "$tmp/bin/xcrun" "$tmp/bin/xcodebuild"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }
run() {  # run [VAR=value...] [args...]: device-run.sh with a clean environment; sets $status
  : >"$tmp/log"
  rm -rf "$ios/build"
  mkdir -p "$tmp/wd"
  env -i HOME="$tmp" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" TMPDIR="$tmp/wd" FAKE_LOG="$tmp/log" FAKE_LEAKS="$tmp/leaks" \
    FAKE_DEVICES="${devices:-$tmp/one.json}" "$@" >"$tmp/out" 2>&1
  status=$?
}
dr="$ios/scripts/device-run.sh"

run "$dr"
(( status != 0 )) && grep -q "no DEVELOPMENT_TEAM" "$tmp/out" && ok "no team: refused" || fail "no team: $(cat "$tmp/out")"

printf 'DEVELOPMENT_TEAM = TEAM123456 // mine\nQUICKR_DEVICE =\n' >"$ios/Local.xcconfig"
run "$dr"
if (( status == 0 )) && grep -q "xcodebuild .*-destination id=00008140-000000000000AAAA -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=TEAM123456 build" "$tmp/log" \
  && grep -q "devicectl device install app --device 00008140-000000000000AAAA .*Debug-iphoneos/QuickR.app" "$tmp/log" \
  && grep -q "devicectl device process launch --device 00008140-000000000000AAAA --terminate-existing com.bahumia.quickr" "$tmp/log"; then
  ok "the only paired iPhone: built (registering the device), installed and launched; the team from Local.xcconfig"
else
  fail "only paired iPhone (status $status): $(cat "$tmp/out") // $(cat "$tmp/log")"
fi

for pick in "Test iPhone" 00008140-000000000000AAAA 11111111-AAAA; do
  devices="$tmp/two.json" run "$dr" "$pick"
  (( status == 0 )) && grep -q "install app --device 00008140-000000000000AAAA" "$tmp/log" && ok "picked by '$pick'" \
    || fail "pick '$pick' (status $status): $(cat "$tmp/out")"
done
devices="$tmp/two.json" run QUICKR_DEVICE="Second iPhone" "$dr"
grep -q "install app --device 00008140-000000000000DDDD" "$tmp/log" && ok "QUICKR_DEVICE from the environment" || fail "QUICKR_DEVICE: $(cat "$tmp/out")"

devices="$tmp/two.json" run "$dr"
(( status != 0 )) && grep -q "several paired iPhones (paired: Second iPhone, Test iPhone)" "$tmp/out" && ! grep -q "xcodebuild" "$tmp/log" \
  && ok "two paired iPhones and none chosen: refused, by name only" || fail "ambiguous (status $status): $(cat "$tmp/out")"
grep -qE "0000|1111|4444" "$tmp/out" && fail "an identifier was printed: $(cat "$tmp/out")" || ok "no identifier printed"
run "$dr" 00008140-000000000000BBBB
(( status != 0 )) && ! grep -q "BBBB" "$tmp/out" && ok "a device given but not found isn't echoed" || fail "echoed: $(cat "$tmp/out")"
run "$dr" "Other iPhone"
(( status != 0 )) && grep -q "no paired iPhone matches the device given (paired: Test iPhone)" "$tmp/out" && ok "an unpaired iPhone isn't used" \
  || fail "unpaired (status $status): $(cat "$tmp/out")"
run "$dr" "Test Watch"
(( status != 0 )) && ok "a watch isn't used" || fail "watch picked: $(cat "$tmp/log")"

run IOS_LAUNCH_ARGS="-QuickrDemoStore" "$dr" "" "quickr://t/water/record"
grep -q "process launch --device 00008140-000000000000AAAA --terminate-existing --payload-url quickr://t/water/record com.bahumia.quickr -QuickrDemoStore" "$tmp/log" \
  && ok "a URL and launch arguments are passed" || fail "url/args: $(cat "$tmp/log")"

# A full run's output, and the watchdog's files, never show the UDID, CoreDevice id, ECID,
# serial number or the Team ID: the chosen device's, another listed device's, or one shaped like
# them that devicectl didn't list.
run "$dr" "" "quickr://t/water/record"
if (( status == 0 )) && grep -q "Test iPhone" "$tmp/out" \
  && ! grep -qE "AAAA|7711|TEAM123456|BBBB|7733|CCCC|1234ABCD|XYZ999|0011223344556677" "$tmp/out"; then
  ok "the output names the device and shows no identifier"
else
  fail "identifiers in the output (status $status): $(cat "$tmp/out")"
fi
grep -q "<device>" "$tmp/out" && grep -q "\*\*\*\*56" "$tmp/out" && ok "identifiers show as <device>, the team redacted" \
  || fail "no redaction marks: $(cat "$tmp/out")"
[[ -s "$tmp/leaks" ]] && fail "identifiers in the watchdog's files: $(sort -u "$tmp/leaks")" || ok "the watchdog's files never held an identifier"

if (( failures )); then
  echo "device-run-test: $failures failed"
  exit 1
fi
echo "device-run-test: all passed"
