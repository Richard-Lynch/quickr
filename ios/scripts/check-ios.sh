#!/usr/bin/env bash
# The local iOS gate: gen, the script tests, swift test (strict pool), the real-time tests, the
# Unit and UI plans on both simulators, the Intents plan on the iOS 27+ one, lint, Xcode version.
# Usage: check-ios.sh <min simulator> <current simulator>
source "$(dirname "$0")/common.sh"
require_xcode
here="$(dirname "$0")"
"$here/check-xcode-version.sh"
"$here/gen.sh"
"$here/tests/watchdog-test.sh"
"$here/tests/sim-cap-test.sh"
"$here/swift-test.sh"
"$here/timing-test.sh"
for sim in "$1" "$2"; do
  "$here/test.sh" Unit "$sim"
  "$here/test.sh" UI "$sim"
  # AppIntentsTesting only loads on an iOS 27+ runtime (project.yml, QuickRIntentsTests).
  udid="$(sim_udid "$sim")"
  major="$(xcrun simctl list devices | awk -v id="$udid" '/^-- iOS /{split($3, v, "."); m=v[1]} index($0, id){print m; exit}')"
  if (( ${major:-0} >= 27 )); then
    "$here/test.sh" Intents "$sim"
  else
    echo "ios: Intents plan skipped on $sim (iOS ${major:-?}; AppIntentsTesting needs 27+)"
  fi
done
"$here/resolved-check.sh"
"$here/lint.sh"
echo "ios: check-ios passed"
