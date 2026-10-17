#!/usr/bin/env bash
# The local iOS gate: gen, swift test, the Unit and UI plans on both simulators, lint, Xcode version.
# Usage: check-ios.sh <min simulator> <current simulator>
source "$(dirname "$0")/common.sh"
require_xcode
here="$(dirname "$0")"
"$here/check-xcode-version.sh"
"$here/gen.sh"
swift test --package-path "$IOS_DIR/QuickrKit"
for sim in "$1" "$2"; do
  "$here/test.sh" Unit "$sim"
  "$here/test.sh" UI "$sim"
done
"$here/lint.sh"
echo "ios: check-ios passed"
